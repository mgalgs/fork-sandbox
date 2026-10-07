# lane-complete

A Claude Code mod (a plugin with a hooks module; needs Claude Code 2.1.287 or
newer) that makes `@` at the prompt complete [lane-mail](../../docs/agent-mail.md)
lanes: `@fs`, `@docs`, `@fs:otherhost`.

## What it does

- `@` typed at a word start (start of the box, or after whitespace) is
  swallowed and opens a picker in the band above the prompt. A mid-word `@`
  (an email address) is left alone.
- The characters you type next filter the list: prefix matches first, then
  substring matches. The list is live lanes (registered sessions), then lanes
  that only have a mailbox, then each of those qualified with each peer host
  from the peers file (`@lane:host`).
- Enter or Tab inserts the highlighted address at the cursor, followed by a
  space.
- Esc inserts a literal `@` (plus anything typed after it) and closes the
  picker.
- `@@`: a second `@` right after the first closes the picker and lets a single
  `@` through, so Claude Code's own agent/file menu opens as usual.
- With no lanes known, `@` is not swallowed at all.
- On submit the text is never rewritten. If it names a known lane, a note for
  the model is attached saying it is a lane-mail address and how to message it
  (`lane-mail.sh send --from @<own lane> --to @<lane> --subject ... --body -`).
  Whether to send, or only to refer to the lane, is Claude's call from your
  wording. The mod never sends anything itself.

## Keys

| Key | In the picker |
| --- | --- |
| letters, digits, `-` `.` `:` | filter |
| Enter, Tab | insert the highlighted lane |
| Up / Down (Ctrl-P / Ctrl-N) | move the highlight |
| Backspace | trim the filter; on an empty filter, drop the `@` |
| Esc | cancel, leaving a literal `@` |
| `@` (on an empty filter) | `@@`: close, pass one `@` to the stock menu |
| space or other punctuation | not a lane: cancel, keeping what was typed |

## Try it

```
claude --plugin-dir mods/lane-complete
```

The lane list is read in the background every few seconds by `bin/list-lanes.sh`
(never per keystroke), which takes the lane-mail root, peers file and registry
directory from the lane-mail scripts. It looks for them in this checkout's
`scripts/` first, then wherever `lane-mail.sh` is on `PATH`.

## Development

```
claude plugin validate mods/lane-complete
claude plugin test mods/lane-complete
tests/lane-complete-list-lanes-test.sh
```

The picker logic is in `hooks/lanes.ts` and has no engine in it;
`hooks/register.tsx` wires it to `prompt.edit`, `prompt.submit` and the band.
