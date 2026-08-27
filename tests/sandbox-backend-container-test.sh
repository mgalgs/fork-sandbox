#!/usr/bin/env bash
set -uo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backend="$repo_dir/scripts/sandbox-backend-container"
pass=0; fail=0; tmpdirs=(); pids=()
cleanup() { local p d; for p in "${pids[@]-}"; do kill "$p" 2>/dev/null || true; done; for d in "${tmpdirs[@]-}"; do [[ -d "$d" ]] && rm -rf -- "$d"; done; }
trap cleanup EXIT
ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; [[ -z "${2:-}" ]] || printf '        %s\n' "$2"; fail=$((fail + 1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1" "expected '$2', got '$3'"; fi; }
refuses() {
    local label="$1" needle="$2" out rc; shift 2
    out="$("$@" 2>&1)"; rc=$?
    if (( rc != 0 )) && [[ "$out" == *"$needle"* ]]; then ok "$label"; else no "$label" "status $rc: $out"; fi
}
# mktemp -d only; registration is the caller's job. A helper that both prints
# a path for capture (`x="$(newdir)"`) and appends to tmpdirs internally
# would do that append inside the command-substitution subshell, where it
# never reaches the parent shell's array -- silently defeating the very
# cleanup it looks like it provides.
newdir() { mktemp -d; }

printf '== validation (no runtime required) ==\n'
w="$(newdir)"; tmpdirs+=("$w"); image=x
refuses "requires workdir" workdir "$backend" --net sealed --image "$image" -- true
refuses "requires network mode" net "$backend" --workdir "$w" --image "$image" -- true
refuses "validates network mode" bogus "$backend" --workdir "$w" --net bogus --image "$image" -- true
refuses "refuses system workdir" refusing "$backend" --workdir /etc --net sealed --image "$image" -- true
refuses "refuses writable system bind" refusing "$backend" --workdir "$w" --net sealed --image "$image" --bind-rw /etc -- true
refuses "requires absolute remap" absolute "$backend" --workdir "$w" --net sealed --image "$image" --bind-ro-at "$w" relative -- true
refuses "rejects remap dot-dot" component "$backend" --workdir "$w" --net sealed --image "$image" --bind-ro-at "$w" /tmp/../etc -- true
refuses "rejects malformed setenv" NAME=VALUE "$backend" --workdir "$w" --net sealed --image "$image" --setenv BROKEN -- true
refuses "bridge requires port" "no port" "$backend" --workdir "$w" --net sealed --image "$image" --bridge /tmp/x -- true
refuses "bridge rejects missing socket" "not a unix socket" "$backend" --workdir "$w" --net sealed --image "$image" --bridge /definitely/missing=3000 -- true
refuses "bridge only sealed" "only with" "$backend" --workdir "$w" --net pinned --image "$image" --bridge /definitely/missing=3000 -- true
refuses "requires command" "no command" "$backend" --workdir "$w" --net sealed --image "$image" --
refuses "rejects unknown option" unknown "$backend" --wat -- true
refuses "requires image" image env -u FORK_SANDBOX_CONTAINER_IMAGE "$backend" --workdir "$w" --net sealed -- true
comma_dir="$(newdir),comma"; mv "${comma_dir%,comma}" "$comma_dir"; tmpdirs+=("$comma_dir")
refuses "rejects comma in mount path" comma "$backend" --workdir "$comma_dir" --net sealed --image "$image" -- true

# A live unix socket is needed to reach port and duplicate-port validation.
sockdir="$(newdir)"; tmpdirs+=("$sockdir"); sock="$sockdir/service.sock"
python3 - "$sock" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(); time.sleep(30)
PY
pids+=("$!")
for _ in {1..50}; do [[ -S "$sock" ]] && break; sleep .02; done
refuses "bridge rejects privileged port" privileged "$backend" --workdir "$w" --net sealed --image "$image" --bridge "$sock=80" -- true
refuses "bridge rejects duplicate port" "two --bridge" "$backend" --workdir "$w" --net sealed --image "$image" --bridge "$sock=3000" --bridge "$sock=3000" -- true
comma_sockdir="$(newdir),comma"; mv "${comma_sockdir%,comma}" "$comma_sockdir"; tmpdirs+=("$comma_sockdir"); comma_sock="$comma_sockdir/service.sock"
python3 - "$comma_sock" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(); time.sleep(30)
PY
pids+=("$!"); for _ in {1..50}; do [[ -S "$comma_sock" ]] && break; sleep .02; done
refuses "rejects comma in generated bridge mount" comma "$backend" --workdir "$w" --net sealed --image "$image" --bridge "$comma_sock=3001" -- true

# A comma in the socket's own FILENAME leaves the mounted directory clean, so
# the mount check above passes it -- but socat reads the comma in its
# UNIX-CONNECT: address as an option separator. That was the one bridge input
# that failed OPEN: socat binds its TCP listener anyway, the readiness probe
# passes, the gate releases, and the command runs behind a relay that can
# never carry a byte.
comma_name_sock="$(newdir)/a,b.sock"; tmpdirs+=("$(dirname "$comma_name_sock")")
python3 - "$comma_name_sock" <<'PY' &
import socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(5)
while True:
    c, _ = s.accept(); c.close()
PY
pids+=("$!"); for _ in {1..50}; do [[ -S "$comma_name_sock" ]] && break; sleep .02; done
refuses "rejects comma in the bridge socket filename" comma "$backend" --workdir "$w" --net sealed --image "$image" --bridge "$comma_name_sock=3002" -- true

printf '\n== Darwin pin route program (no runtime required) ==\n'
# The Darwin branch only runs on a Mac, which is why it has never executed in
# any test. It does not need a Mac to run, though: every input it reads comes
# from a command on PATH, so stubbing `uname`, `route`, `netstat` and
# `ifconfig`, plus a fake container CLI that records the route program instead
# of running it, drives the real code path on any host.
#
# The fixture below is REPRESENTATIVE, not captured from a Mac -- so the
# assertions deliberately test properties that hold whatever a real routing
# table looks like, rather than an exact expected string. Asserting an exact
# program against an invented fixture would only prove the code matches the
# guess. In particular, "every blackhole operand carries a prefix length"
# catches the whole class of mis-parses without anyone having to predict which
# one macOS produces.
#
# Every address here is from the RFC 5737 documentation ranges rather than a
# private range, so the fixture cannot be mistaken for anyone's real network.
dwn="$(newdir)"; tmpdirs+=("$dwn")
mkdir -p "$dwn/bin" "$dwn/work"
cat > "$dwn/bin/uname" <<'EOF'
#!/bin/sh
[ "$1" = "-s" ] && { echo Darwin; exit 0; }
exec /usr/bin/uname "$@"
EOF
cat > "$dwn/bin/route" <<'EOF'
#!/bin/sh
cat <<'OUT'
   route to: default
destination: default
       mask: default
    gateway: 192.0.2.1
  interface: en0
      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING,GLOBAL>
OUT
EOF
# macOS netstat abbreviates classful destinations (no /len) and prints an
# Expire column, so $NF is not always the interface. Both are in the fixture
# on purpose: they are the two things most likely to trip the parser.
cat > "$dwn/bin/netstat" <<'EOF'
#!/bin/sh
cat <<'OUT'
Routing tables

Internet:
Destination        Gateway            Flags        Netif Expire
default            192.0.2.1          UGScg          en0
127                127.0.0.1          UCS            lo0
192.0.2            link#15            UCS            en0      !
192.0.2.1/32       link#15            UCS            en0
198.51.100/24      link#22            UCS         utun4
100.64.0.0/10      link#22            UCS         utun4
OUT
EOF
cat > "$dwn/bin/ifconfig" <<'EOF'
#!/bin/sh
cat <<'OUT'
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet 192.0.2.198 netmask 0xffffff00 broadcast 192.0.2.255
OUT
EOF
cat > "$dwn/bin/fakecli" <<EOF
#!/usr/bin/env bash
# Records the pin helper's route program, fakes everything else.
case "\$1 \$2" in
  "network create") echo fake-net; exit 0 ;;
  "network inspect") case "\$*" in *Gateway*) echo 203.0.113.1 ;; *Subnet*) echo 203.0.113.0/24 ;; esac; exit 0 ;;
  "network rm") exit 0 ;;
esac
case "\$1" in
  create) echo fake-container; exit 0 ;;
  start)  exit 0 ;;
  wait)   echo 0; exit 0 ;;
  rm)     exit 0 ;;
  inspect) echo 2026-01-01T00:00:00Z; exit 0 ;;
  run)
    for a in "\$@"; do prev_is_c=\${is_c:-0}; done
    # the pin helper is the only 'run' carrying --cap-add=NET_ADMIN
    if [[ "\$*" == *NET_ADMIN* ]]; then
      prog=""; while (( \$# )); do [[ "\$1" == "-c" ]] && { prog="\$2"; break; }; shift; done
      printf '%s' "\$prog" > "$dwn/routes.txt"
    fi
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$dwn/bin/"*
rm -f "$dwn/routes.txt"
PATH="$dwn/bin:$PATH" FORK_SANDBOX_CONTAINER_CLI="$dwn/bin/fakecli" \
    "$backend" --workdir "$dwn/work" --net pinned --image fake -- true >/dev/null 2>&1
if [[ ! -s "$dwn/routes.txt" ]]; then
    no "Darwin branch generates a route program" "no program captured"
else
    ok "Darwin branch generates a route program"
    dprog="$(cat "$dwn/routes.txt")"
    case "$dprog" in "set -e;"*) ok "Darwin program is prefixed with set -e" ;;
        *) no "Darwin program is prefixed with set -e" "$dprog" ;; esac
    case "$dprog" in *"; ip route add blackhole 169.254.0.0/16") ok "Darwin sentinel is installed last" ;;
        *) no "Darwin sentinel is installed last" "tail: ${dprog##*;}" ;; esac
    case "$dprog" in *"ip route replace blackhole 203.0.113.1/32"*) ok "Darwin blackholes the gateway /32" ;;
        *) no "Darwin blackholes the gateway /32" "$dprog" ;; esac
    if [[ "$dprog" == *"blackhole 203.0.113.0/24"* ]]; then
        no "Darwin never blackholes the container subnet" "$dprog"
    else ok "Darwin never blackholes the container subnet"; fi
    # The class-catching assertion, and the reason it is about the slash
    # rather than about the address. iproute2 is lenient in two different
    # ways, and only one of them is safe:
    #
    #   - An abbreviated prefix WITH a length -- three octets and /24, say --
    #     expands to the network you meant. macOS netstat prints destinations
    #     in exactly that form, so those must be allowed through.
    #   - An operand with NO length is also accepted, and silently becomes a
    #     single /32 host route instead of the network. A denial that looks
    #     installed and covers one address out of the whole prefix is the
    #     dangerous outcome, and it is silent.
    #
    # Requiring the slash separates the two, and it catches the whole
    # mis-parse class without predicting which form macOS emits.
    bad=""
    while read -r op; do
        [[ -n "$op" ]] || continue
        [[ "$op" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){0,3}/[0-9]{1,2}$ ]] || bad+="$op "
    done < <(printf '%s' "$dprog" | tr ';' '\n' | awk '/ip route (add|replace) blackhole /{print $NF}' | grep -v '^default$')
    if [[ -z "$bad" ]]; then ok "Darwin blackhole operands all carry a prefix length"
    else no "Darwin blackhole operands all carry a prefix length" "no prefix length: $bad"; fi
    # NOT covered, and the reason this harness exists rather than a claim of
    # correctness: whether the LAN-restore loop actually restores the LAN on a
    # Mac. With the fixture above it restores only the router's own /32, never
    # the surrounding LAN network, because that loop filters on `$1 ~ /\//` and
    # on `$NF == dev` -- and macOS netstat prints an abbreviated destination
    # with no prefix length for a classful network, and an Expire column that
    # makes $NF `!` rather than the interface. A real Mac's LAN sits in one of
    # the three private ranges the fixed denials already cover, so if both of
    # those hold there, nothing punches it back through and pinned mode reaches
    # the router but no other LAN host -- contradicting guarantee 3's "it does
    # reach the host's LAN". (The fixture's own LAN is a documentation range,
    # outside those denials, so the effect is not visible here; only the
    # restore loop's output is.)
    #
    # That is fail-closed, so it is a functional divergence rather than a hole
    # -- and it is unconfirmed, because the fixture is representative rather
    # than captured. Anyone with a Mac can settle it in one step: replace the
    # netstat and ifconfig stubs above with real output from that machine and
    # re-run. Until someone does, the script header's "the Darwin routing
    # branch itself remains unverified" is the honest statement.
fi

printf '\n== runtime integration ==\n'
runtime="${FORK_SANDBOX_CONTAINER_CLI:-docker}"
if ! command -v "$runtime" >/dev/null 2>&1 || ! "$runtime" info >/dev/null 2>&1; then
    printf '  SKIP  runtime unavailable; validation half only\n'
else
    image="fork-sandbox-container-test:$RANDOM-$$"
    if ! "$runtime" build -t "$image" "$repo_dir/tests/container-backend-image" >/dev/null; then
        printf '  SKIP  test image build failed (the machine may be offline)\n'
    else
        run() { FORK_SANDBOX_CONTAINER_CLI="$runtime" "$backend" --image "$image" "$@"; }
        rw="$(newdir)"; tmpdirs+=("$rw"); ro="$(newdir)"; tmpdirs+=("$ro"); printf 'readable\n' >"$ro/file"
        # shellcheck disable=SC2016  # expanded by bash inside the container
        out="$(run --workdir "$rw" --net sealed -- bash -c 'printf "%s|" "$HOME"; find "$HOME" -mindepth 1 -print -quit')"
        check "HOME path and emptiness" "$HOME|" "$out"
        export FORK_SANDBOX_SECRET_SHOULD_NOT_LEAK=secret
        # shellcheck disable=SC2016  # expanded by bash inside the container
        out="$(run --workdir "$rw" --net sealed --setenv PASSED='right value' -- bash -c 'printf "%s|%s|%s" "${FORK_SANDBOX_SECRET_SHOULD_NOT_LEAK-unset}" "${IMAGE_BAKED_SECRET-unset}" "$PASSED"')"
        check "environment allowlist includes image ENV" "unset|unset|right value" "$out"
        out="$(run --workdir "$rw" --net sealed -- /opt/image-tool)"
        check "image-only absolute command" image-tool "$out"
        run --workdir "$rw" --net sealed --bind-ro "$ro" -- bash -c 'touch written; cat '"$ro"'/file; ! touch '"$ro"'/blocked' >/dev/null
        if [[ -f "$rw/written" && "$(stat -c %u:%g "$rw/written")" == "$(id -u):$(id -g)" ]]; then ok "persistent writes are host-owned; read-only bind rejects writes"; else no "persistent writes are host-owned; read-only bind rejects writes"; fi
        run --workdir "$rw" --net sealed -- bash -c 'exit 42' >/dev/null 2>&1; check "exit 42 passes through" 42 "$?"
        run --workdir "$rw" --net sealed -- bash -c 'kill -9 $$' >/dev/null 2>&1; check "self-SIGKILL reports 137" 137 "$?"
        if run --workdir "$rw" --net sealed -- bash -c 'exec 3<>/dev/tcp/1.1.1.1/443' >/dev/null 2>&1; then no "sealed public egress fails"; else ok "sealed public egress fails"; fi
        if run --workdir "$rw" --net sealed -- bash -c 'exec 3<>/dev/tcp/example.com/443' >/dev/null 2>&1; then no "sealed DNS fails"; else ok "sealed DNS fails"; fi

        default_iface="$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')"
        host_addr="$(ip -4 -brief addr show dev "$default_iface" | awk '{split($3,a,"/"); print a[1]; exit}')"
        # shellcheck disable=SC2016  # function is evaluated inside the container
        probe='probe(){ local h=$1 p=${2:-443} e; e=$(timeout 3 bash -c "exec 3<>/dev/tcp/$h/$p" 2>&1); case $e in *"Invalid argument"*|*"Network is unreachable"*) echo unreachable;; *"Connection refused"*) echo reached;; "") echo reached;; *) echo timeout;; esac; }'
        out="$(run --workdir "$rw" --net pinned -- bash -c "$probe; probe 1.1.1.1; probe '$host_addr'")"
        check "pinned public reachable, host address unreachable" $'reached\nunreachable' "$out"

        # Discover the per-run gateway inside; it must be blackholed as a destination.
        out="$(run --workdir "$rw" --net pinned -- bash -c "$probe; gw=\$(ip route | awk '/default/{print \$3}'); probe \"\$gw\"")"
        check "pinned gateway destination unreachable" unreachable "$out"

        tcp_port=$((20000 + RANDOM % 20000)); socat "TCP-LISTEN:$tcp_port,bind=127.0.0.1,reuseaddr,fork" EXEC:/bin/true & pids+=("$!")
        out="$(run --workdir "$rw" --net pinned -- bash -c "$probe; probe 127.0.0.1 '$tcp_port'; gw=\$(ip route|awk '/default/{print \$3}'); probe \"\$gw\" '$tcp_port'")"
        # Connection-refused at container loopback proves the host listener was
        # not reached; the gateway address itself is blackholed.
        check "host loopback listener unreachable by loopback and gateway" $'reached\nunreachable' "$out"

        usock="$sockdir/bridge.sock"; rm -f "$usock"; socat "UNIX-LISTEN:$usock,fork" SYSTEM:'printf bridged' & pids+=("$!"); for _ in {1..50}; do [[ -S "$usock" ]] && break; sleep .02; done
        out="$(run --workdir "$rw" --net sealed --bridge "$usock=23456" -- bash -c 'exec 3<>/dev/tcp/127.0.0.1/23456; cat <&3')"
        check "sealed unix-socket bridge" bridged "$out"

        # What gets mounted is the socket's REAL directory, so the path the
        # generated bootstrap connects to and watches has to be canonical
        # too. When it was left raw, a --bridge path through a symlink named
        # a directory that does not exist inside the container: socat could
        # not connect and the watchdog's first `-S` test was already false,
        # so the run died instantly with a bare 143 and said nothing.
        ln -sfn "$sockdir" "$sockdir/../bridge-link"
        out="$(run --workdir "$rw" --net sealed --bridge "$sockdir/../bridge-link/bridge.sock=23458" -- bash -c 'exec 3<>/dev/tcp/127.0.0.1/23458; cat <&3')"
        check "sealed bridge through a symlinked socket path" bridged "$out"
        rm -f "$sockdir/../bridge-link"

        # A bridge readiness probe is a TCP connect against the relay's own
        # listening port; a socat that has bound and is `fork`-ing does not
        # validate its UNIX-CONNECT target until a client actually arrives.
        # So a unix socket with no listener behind it (previously tested
        # here) cannot exercise the timeout path: the probe still succeeds
        # against socat's own listener, and only a later real connection
        # would see the dead peer. To exercise a listener that genuinely
        # never appears, build an image where socat exists (so the
        # pre-flight `command -v socat` probe, which runs with the image's
        # own default PATH, passes) but is not reachable on this backend's
        # fixed sandbox PATH, so the generated bootstrap's bare `socat`
        # invocation fails with "not found" and no listener ever binds. The
        # bridge socket itself only needs to pass the host-side "-S" check;
        # it never gets a connection attempt, so it need not be live.
        dead_sock="$sockdir/dead.sock"
        python3 - "$dead_sock" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()
PY
        nosocat="fork-sandbox-container-nosocat:$RANDOM-$$"
        if "$runtime" build -t "$nosocat" -f - "$repo_dir" >/dev/null <<'EOF'
FROM alpine:3.22
RUN apk add --no-cache bash socat
# Alpine ships socat as a symlink to socat1, so moving what `command -v`
# reports moves the LINK and strands its target: the result is a dangling
# symlink and an image with no usable socat at all, which the pre-flight
# probe then refuses -- the wrong path for this test. Move the real binary
# and drop the stale link.
RUN mkdir -p /outside-sandbox-path \
 && mv "$(readlink -f "$(command -v socat)")" /outside-sandbox-path/socat \
 && rm -f /usr/bin/socat
ENV PATH="/outside-sandbox-path:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF
        then
            marker="$rw/bridge-must-not-run"
            refuses "unreachable bridge listener fails closed" "did not become ready" \
                "$backend" --image "$nosocat" --workdir "$rw" --net sealed --bridge "$dead_sock=23457" -- touch "$marker"
            if [[ ! -e "$marker" ]]; then ok "unreachable bridge listener did not run command"; else no "unreachable bridge listener did not run command"; fi
            "$runtime" image rm "$nosocat" >/dev/null 2>&1 || true
        else printf '  SKIP  no-PATH-socat image build failed\n'; fi

        noip="fork-sandbox-container-noip:$RANDOM-$$"
        if "$runtime" build -t "$noip" -f - "$repo_dir" >/dev/null <<'EOF'
FROM alpine:3.22
RUN apk add --no-cache bash
EOF
        then
            marker="$rw/must-not-run"; refuses "missing ip fails closed" iproute2 "$backend" --image "$noip" --workdir "$rw" --net pinned -- touch "$marker"
            if [[ ! -e "$marker" ]]; then ok "failed gate did not run command"; else no "failed gate did not run command"; fi
            "$runtime" image rm "$noip" >/dev/null 2>&1 || true
        else printf '  SKIP  no-ip image build failed\n'; fi
        "$runtime" image rm "$image" >/dev/null 2>&1 || true
    fi
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
