---
name: lane-mail-register
description: Register this session in lane mail, reusing the lane name last used for this project directory or inventing one from the session's context, and name its tmux window after the lane; and find which lanes exist and which session holds one. Use when the user says "register in lane mail", "take a lane", "join lane mail", names a lane to take, asks to "list lanes", or you need to address another lane.
argument-hint: "[lane] — optional lane name; guessed when omitted"
---

# Register in lane mail

Lane mail itself (`lane-mail.sh`, `lane-mail-watch.sh`, the hooks) is
documented in this repo's `docs/agent-mail.md`. This skill picks a lane
name, runs the registration, and says how to find other lanes.

Directory→lane choices are remembered in
`~/.local/state/fork-sandbox/lanes.json`, a flat JSON object keyed by
absolute project directory:

```json
{"/home/user/src/frontend": "fe", "/home/user/src/backend": "be"}
```

## Steps

1. **Pick the lane.** The key is this session's primary working directory
   (from the environment block), not wherever the Bash cwd has drifted to.
   - An argument was given: use it, minus any leading `@`.
   - Otherwise Read `lanes.json` and use the entry for the key. A missing
     file or key just means no entry.
   - Otherwise invent one from the session's context: what this session is
     orchestrating, else the project's name. Keep it short (2–6 chars, like
     `fe` or `infra`) and matching `^[a-z0-9][a-z0-9-]*$`.

2. **Register:** `lane-mail.sh register <lane>`. It replaces any lane this
   session already held.

3. **Remember it.** If the lane differs from the file's entry for the key,
   or there was none, write the updated object back (Write the whole file;
   create it if missing). Leave other keys untouched.

   **Name the window.** When `$TMUX` is set, run
   `tmux rename-window -t "$TMUX_PANE" <lane>`, so the operator can tell
   from the status bar which window holds which lane. `-t "$TMUX_PANE"`
   targets this session's own window, not whichever one has focus.

4. **Catch up and arm the watch.** Run `lane-mail.sh inbox <lane>` and
   handle anything unread, marking it `seen`. Then start
   `lane-mail-watch.sh <lane> --wait` as a background Bash command (not a
   Monitor), as `register`'s own output instructs.

   **A registered lane always has a watch armed.** `--wait` exits after
   each delivery, so every wake ends the same way: handle the mail, mark it
   `seen`, relaunch the watch. A turn that leaves the lane registered with
   no watch running means the lane goes deaf.

5. **Report in one line** — the lane and where the name came from:
   `Registered as @fe (from lanes.json)` / `(as asked)` /
   `(guessed from context — say if you want another)`.

## Finding lanes

`lane-mail.sh lanes` lists them, one `<source><TAB><lane>` line each:

| source | meaning |
|---|---|
| `live` | some session registered it. Registrations are never cleaned up, so that session may be gone. |
| `mailbox` | has a mailbox here, no registration |
| `remote` | `lane:host`, a lane on another host that has written here |
| `peer` | a host from the peers file; its lanes are `@<lane>:<peer>` |

`lane-mail.sh list` lists *messages*, not lanes. There is no other lane
subcommand, so do not guess one, and do not read the registry or the
mail root by hand.

To reach the session behind a lane **now**, use `ListAgents`: session
names usually start with the lane (`frontend-2` holds `@frontend`). Send
lane mail to `@<lane>` when the message should survive a handoff;
`SendMessage` the session when it needs a turn right away.
