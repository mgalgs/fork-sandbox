# Visual browser driving in a sandboxed run

**Status: built for the bwrap backend.** G1 (detect), G2 (announce) and G3
(smoke) are all implemented and tested for `bwrap`. The container backend
gets G1/G2 too, but today that is always the announced-absence path: the
default image ships no browser, so there is nothing yet for a container G3
smoke to screenshot — it waits on a browser-carrying image.

The goal: a sandboxed agent can render the app it is working on and *see*
it — one-shot screenshots at minimum, stateful driving (click, type,
inspect, screenshot again) where the repo provides tooling — with
everything inside the sandbox. No host-side browser service, no new
writable surface, no change to the egress story.

Why it matters: design iteration is the class of task where an unattended
agent is blind today. An agent restyling a page can run the suite and pass
while shipping something visually broken; the loop that catches that is
render → look → adjust, and it needs eyes inside the run.

## What already exists

More of this works today than it first appears. The design below is mostly
*guaranteeing* and *documenting* existing behavior, not building new
machinery.

- **A system browser reaches the sandbox via `/usr`, `/opt` or
  `/nix/store`.** The sandbox mounts these read-only, so a host chromium
  resolved under any of them is on PATH inside. This is host-dependent —
  nothing checks for it or tells the session about it.
- **The Playwright browser cache is bound read-only** when the host has
  one (`~/.cache/ms-playwright`, hardcoded by Playwright), so
  Playwright-driven suites and tools find a browser without a doomed
  `playwright install`. Also host-dependent, also silent.
- **The scripts toolbox is bound in**, and it carries a one-shot
  URL-to-PNG screenshot script. Serviceable for "render this page and
  look at it" on a claude harness.
- **The claude harness has vision.** A session that writes a PNG can Read
  it and actually see it. This is the piece that makes in-sandbox
  screenshots useful without any new plumbing.
- **The outbox surfaces images to the orchestrator.** A run that saves
  screenshots to the outbox gives the launching session (and the human)
  the same evidence, which is how a vision-less harness still
  participates — see below.
- **Per-run services** give the app a database, so `runserver` inside the
  sandbox can serve real pages. Loopback inside the sandbox's network
  namespace connects the app and the browser with no egress implications.

## The gaps

1. **No guarantee, no announcement.** Whether a browser exists inside a
   given sandbox is an accident of the host. A session that assumes one
   burns its run discovering otherwise; a session that assumes none never
   tries. The services section of the generated prompt is the model: the
   run should be *told* what it has.
2. **Chromium's sandbox under bwrap needs one verified answer.** Nested
   sandboxing (user namespaces inside the bwrap namespace) either works on
   a given kernel/config or needs `--no-sandbox`, and "try flags until it
   renders" is exactly the kind of discovery an unattended session should
   never spend its run on. The answer must be established once, on each
   supported backend, and encoded — in the wrapper or the prompt, not in
   folklore. **Settled**: encoded as the `chromium_own_sandbox` capability
   key (see [sandbox-backend.md](sandbox-backend.md)'s capabilities
   section), which `fs_backend_capabilities` parses and G2's prompt
   section reads to flip its `--no-sandbox` sentence.
3. **Stateful driving is repo tooling, not harness tooling.** A
   ref-driven Playwright CLI (a repo may commit one under its own tree,
   e.g. `etc/browser-tools/`) wants project-specific setup — which page,
   which fixtures, which viewport. That belongs in the repo, provisioned
   like a venv, not baked into fork-sandbox.
4. **Vision-less harnesses can't look.** A `pi` run on a text-only model
   can drive a browser but cannot judge a pixel. The loop for those runs
   inverts: screenshots land in the outbox, and the *orchestrator* (or a
   review leg on a vision model) judges them between rounds.

## The contract, proposed

fork-sandbox guarantees three things; a repo owns the rest.

**G1 — detect and bind.** At launch, detect a usable browser: the
Playwright cache (bind read-only, as today) or a system chromium under
`/usr`, `/opt` or `/nix/store`. Nothing new is mounted that isn't already;
detection just records what is true.

**G2 — announce.** When a browser is present, the generated prompt gains a
`## Browser` section naming the binary (or cache path), the flags that are
known to work in this sandbox backend (the settled answer to gap 2,
`--no-sandbox` included if that is what it takes), and the screenshot
recipe: write PNGs into the clone or the outbox, Read them (claude), or
save them to the outbox for the orchestrator (all harnesses). When no
browser is present, the section says so — one line, so the session never
spends tool calls discovering absence.

**G3 — verify per backend.** A smoke check in fork-sandbox's own test rig:
start a static server in a sandboxed run, screenshot it, assert the PNG is
non-trivial. Run per sandbox backend (bwrap today, container backend when
it lands), because gap 2's answer is backend-specific.

**The repo's half** (documented, not enforced): commit driver tooling
under its own tree (e.g. `etc/browser-tools/agent-browser`), list its
`node_modules` (or venv) in `.agents/sandbox-services/provision-ro` so it
works offline, and teach its own agents the recipe in the repo's CLAUDE.md
— which page to serve, which entry URL to drive, where to save evidence.

**The vision-less loop** (documented pattern, no code): a run on a
text-only model saves `outbox/screenshots/<step>-<slug>.png` at every
checkpoint the handoff names; the orchestrator reads them between rounds,
or a `--review-loop` leg on a vision model does. The handoff must say
which checkpoints, because a text-only session cannot judge which states
are worth capturing.

## Explicitly not building

- **No browser MCP server or daemon in fork-sandbox.** The agent drives a
  CLI or a library; persistent browser state is the repo's tool's problem.
- **No host-side browser bridge.** The browser runs inside the sandbox or
  not at all — a bridge would be a new writable surface and a new egress
  path, for no capability the in-sandbox browser lacks.
- **No screenshot-diffing framework.** Judging renders is the agent's and
  reviewer's job; tooling for pixel diffs can live in a repo that wants
  it.

## Open questions (to settle before building)

- Q1 — **answered for bwrap** (measured 2026-09-18, Arch, chromium via
  `/usr` inside a read-only network-less bwrap): chromium's own sandbox
  works; `--headless=new --disable-gpu --disable-dev-shm-usage
  --screenshot=...` renders with **no `--no-sandbox`**. Stderr shows
  harmless dbus noise. G2's wording for the bwrap backend can state
  exactly those flags. The container backend still needs its own run of
  the same experiment.
- Q2 — **settled**: announce both when both exist, rather than picking one.
  Chromium carries the screenshot recipe; the Playwright cache serves repo
  tooling (agent-browser, say) that resolves through Playwright's own
  lookup regardless of what G2 says about chromium.
- Q3: is a headed (non-headless) mode ever worth supporting in-sandbox
  (via Xvfb) for tools that misbehave headless? Leaning no until a real
  task hits it.
