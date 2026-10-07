import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { LanePicker } from '../types'
import { VISIBLE, matchLanes, mentionContext, mentions, parseLanes, step } from './lanes'
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
  // `@`; open, it owns the keys until Enter, Tab, Esc, Backspace-on-empty or a
  // non-lane character closes it. The text itself is edited here, in the
  // answer, so nothing depends on the band taking keyboard focus.
  on('prompt.edit', async ($, e, next) => {
    const open = await read($, picker)
    if (open === null && !(e.inputText === '@' && e.start === e.end)) return next(e)

    const result = step(open, lanes, e)
    if (result.picker !== open) await update($, picker, () => result.picker)

    return result.box ?? next(e)
  })

  // A submit never rewrites the text: it only adds a note for the model when
  // the prompt names a lane.
  on('prompt.submit', async ($, e, next) => {
    if ((await read($, picker)) !== null) await update($, picker, () => null)

    const named = mentions(e.text, lanes)
    if (named.length === 0) return next(e)

    return next({ ...e, context: [...(e.context ?? []), mentionContext(named)] })
  }).catch(($, e, next) => next(e)) // a failed note never costs the operator the prompt

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const open = await read($, picker)
    if (open === null) return next(e)

    const { Box, Text } = $.ui.resolve(e)
    const matches = matchLanes(lanes, open.filter)
    const at = Math.min(open.index, Math.max(matches.length - 1, 0))
    const first = Math.max(0, Math.min(at - Math.floor(VISIBLE / 2), matches.length - VISIBLE))
    const shown = matches.slice(first, first + VISIBLE)

    return (
      <Box flexDirection="column">
        <Text bold>
          lane @{open.filter}
          <Text dimColor> ({matches.length} of {lanes.length})</Text>
        </Text>
        {shown.length === 0 && <Text dimColor>  no lane matches; Enter keeps @{open.filter} as typed</Text>}
        {shown.map((lane, i) => (
          <Text key={lane.address} bold={first + i === at} color={first + i === at ? 'cyan' : undefined} dimColor={lane.source === 'peer' && first + i !== at}>
            {first + i === at ? '> ' : '  '}
            {lane.address}
          </Text>
        ))}
        <Text dimColor>Enter/Tab insert · Up/Down choose · Backspace/Esc cancel · @ again: stock menu</Text>
      </Box>
    )
  })
}
