import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { LanePicker } from '../types'
import { VISIBLE, finish, highlighted, matchLanes, mentionContext, mentions, parseLanes, plain, shown, step } from './lanes'
import type { Lane } from './lanes'

// How often the lane list is re-read, in the background; never per keystroke.
const REFRESH_MS = 5000

const picker = atom({ plugin: 'lane-complete', key: 'picker' } as const, null as LanePicker | null)

// The lane list the hooks read: refreshed by a timer, so never read per
// keystroke. A reload starts it empty and session.start fills it again; a
// failed read keeps the last good list (a missed refresh is not worth a toast).
let lanes: Lane[] = []

async function refresh($: EngineInterface) {
  try {
    const ran = await $.process.run(['bash', `${$.plugin.root}/bin/list-lanes.sh`], { timeoutMs: 5000 })
    if (ran.exitCode === 0) lanes = parseLanes(ran.stdout)
  } catch {
    // keep the last list
  }
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await refresh($)
    $.clock.every(REFRESH_MS, () => refresh($))

    return next(e)
  })

  // Every edit goes through the picker. Closed, it passes all but a word-start
  // `@`; open, it owns the edits until Backspace-on-empty, a cursor move or a
  // non-lane character closes it, or Enter takes the choice (below). The text
  // itself is edited here, in the answer, so nothing depends on the band
  // taking keyboard focus. Only edits arrive here: Enter, Tab, Esc and
  // Up/Down never do.
  on('prompt.edit', async ($, e, next) => {
    const open = await read($, picker)
    if (open === null && !(e.inputText === '@' && e.start === e.end)) return next(e)

    const result = step(open, lanes, e)
    if (result.picker !== open) await update($, picker, () => result.picker)

    if (result.replay !== undefined) return next({ ...e, ...result.replay })
    return result.box ?? next(e)
  })

  // Enter with the picker open is the choice, not a send: the submit is
  // dropped and the box put back with the best match (or, with none, as it
  // stands, `@` and filter in it as plain text) in place of the `@` and what was typed.
  // Otherwise a submit never rewrites the text: it only adds a note for the
  // model when the prompt names a lane.
  on('prompt.submit', async ($, e, next) => {
    const open = await read($, picker)
    if (open !== null) {
      await update($, picker, () => null)
      if (e.text.trim() === shown(open).text.trim()) {
        // The cursor ends at the box's end: fill has no way to place it.
        await $.prompt.fill({ text: finish(open, lanes).text, mode: 'replace' })
        return { drop: 'lane picked' }
      }
      // A box that is not the one shown was changed behind the picker: send it
      // as it is, with a real `@` for the mark and without the space we added.
      e = { ...e, text: plain(open, e.text).text }
    }

    const named = mentions(e.text, lanes)
    if (named.length === 0) return next(e)

    return next({ ...e, context: [...(e.context ?? []), mentionContext(named)] })
  }).catch(($, e, next) => next(e)) // a failed note never costs the operator the prompt

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const open = await read($, picker)
    if (open === null) return next(e)

    const { Box, Text } = $.ui.resolve(e)
    const matches = matchLanes(lanes, open.filter)
    const shown = matches.slice(0, VISIBLE)
    const current = highlighted(open, lanes)

    return (
      <Box flexDirection="column">
        <Text bold>
          lane @{open.filter}
          <Text dimColor> ({matches.length} of {lanes.length})</Text>
        </Text>
        {shown.length === 0 && <Text dimColor>  no lane matches; Enter keeps @{open.filter} as typed</Text>}
        {shown.map((lane, i) => (
          <Text key={lane.address} bold={i === current} color={i === current ? 'cyan' : undefined} dimColor={lane.source === 'peer' && i !== current}>
            {i === current ? '> ' : '  '}
            {lane.address}
          </Text>
        ))}
        <Text dimColor>Enter inserts the marked row · C-f next, C-b previous · keep typing to narrow · Backspace trims · space cancels · @ again: stock menu</Text>
      </Box>
    )
  })
}
