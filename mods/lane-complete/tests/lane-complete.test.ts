import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

import { MARK, finish, matchLanes, mentions, parseLanes, plain, shown, step } from '../hooks/lanes'
import type { Edit, Lane } from '../hooks/lanes'
import type { LanePicker } from '../types'

// Invented lanes: two local ones (one live, one mailbox-only) and one peer host.
const LIST = 'live\talpha\nmailbox\tbeta\npeer\thostone\nlive\tBad Lane\n'

const answered = (stdout: string) => ({
  value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
})

/**
 * The prompt box as the engine's editor keeps it, driven one key at a time.
 * Only keys that arrive as edits go through prompt.edit; Enter is a submit,
 * and an empty box is never submitted (Claude Code fires nothing for it).
 */
function composer($: any, on: On) {
  const box = shared
  Object.assign(box, { text: '', cursor: 0 })
  const send = async (edit: Partial<Edit> & { inputText: string }) => {
    const r = await $.prompt.edit({
      text: box.text,
      cursor: box.cursor,
      start: box.cursor,
      end: box.cursor,
      origin: { kind: 'composer' },
      ...edit,
    })
    box.text = r.text
    box.cursor = r.cursor
    return { ...box }
  }
  return {
    box,
    type: async (chars: string) => {
      let last = { ...box }
      for (const ch of chars) last = await send({ key: { key: ch }, inputText: ch })
      return last
    },
    press: (name: string) => send({ key: { key: name }, inputText: '' }),
    // C-f / C-b: the editor's cursor-forward/back, an edit with no text. At the end of the box the editor
    // makes no edit at all (nothing can move), which is what the trailing space is for.
    ctrl: async (name: 'f' | 'b') => {
      if (name === 'f' && box.cursor >= box.text.length) return { ...box }
      return send({ key: { key: name, ctrl: true }, inputText: '' })
    },
    // Enter: a submit of the box. A dropped one leaves the box as the hook filled it.
    enter: async () => {
      const text = box.text
      if (text.trim() === '') return { drop: 'empty box', box: { ...box } }
      const r = await $.prompt.submit({ text, wait: false, origin: { kind: 'composer' } })
      if (r.drop === undefined) Object.assign(box, { text: '', cursor: 0 })
      return { ...r, box: { ...box } }
    },
    backspace: () => send({ key: { key: 'backspace' }, inputText: '', start: Math.max(box.cursor - 1, 0) }),
  }
}

// The box prompt.fill writes: registered in started(), before the test's first call on `$`.
const shared = { text: '', cursor: 0 }

async function started($: any, on: On, stdout = LIST) {
  mock.clock(on)
  on('process.run', () => answered(stdout))
  // The engine's own bottoms: the splice an edit makes, and a prompt entering.
  on('prompt.edit', (_, e) => {
    // C-f / C-b are cursor moves: the text stays, the cursor steps.
    if (e.key?.ctrl === true && (e.key.key === 'f' || e.key.key === 'b')) {
      return { text: e.text, cursor: e.cursor + (e.key.key === 'f' ? 1 : -1) }
    }
    return {
      text: e.text.slice(0, e.start) + e.inputText + e.text.slice(e.end),
      cursor: e.start + e.inputText.length,
    }
  })
  on('prompt.submit', (_, e) => ({ text: e.text, context: e.context }))
  // `replace` puts the text in with the cursor at its end.
  on('prompt.fill', (_, e) => {
    shared.text = e.mode === 'replace' ? e.text : shared.text + e.text
    shared.cursor = shared.text.length
    return { isFilled: true, text: shared.text, cursor: shared.cursor }
  })
  // The engine draws nothing in the band when no plugin does.
  on('ui.render', () => ({ type: 'Box', props: {}, children: [] }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  await $.session.start({ cwd: '/work', surface: 'terminal', isInteractive: true })
}

// What the band above the prompt says: its first line while the picker is
// open ("lane @<filter>"), or undefined while it is closed and the band is empty.
async function band($: any) {
  const props = { hasSurvey: false, isWorking: false, maxRows: 20, bodyColumns: 80, scroll: { bodyRows: 18, offset: 0, total: 0 } }
  const ui = await $.ui.mount({ plugin: 'lane-complete', surface: 'terminal', component: 'AbovePrompt', props })
  const head = await ui.find({ type: 'Text', text: /^lane @/ })
  const rows = (await ui.findAll({ type: 'Text', text: /^[> ] @/ })).map((r: { text: string }) => r.text.trim())
  await ui.unmount()
  return head === undefined ? undefined : { head: head.text, rows }
}

test('@ at the start of the box is swallowed and opens the picker', async ($, on) => {
  await started($, on)
  const c = composer($, on)
  // The box holds the mark, not an ASCII @, which would open the stock menu over the picker.
  expect(await c.type('@')).toEqual({ text: `${MARK} `, cursor: 1 })
  expect((await band($))?.head).toContain('lane @')
})

test('@ after whitespace opens the picker; mid-word @ is an email and passes through', async ($, on) => {
  await started($, on)
  const c = composer($, on)
  await c.type('hi ')
  await c.type('@')
  expect(c.box.text).toBe(`hi ${MARK} `)
  expect(await band($)).toBeDefined()

  const m = composer($, on)
  await m.type('me')
  expect(await m.type('@')).toEqual({ text: 'me@', cursor: 3 })
  expect(await band($)).toBeUndefined()
})

test('@@ passes a single @ through and closes the picker', async ($, on) => {
  await started($, on)
  const c = composer($, on)
  await c.type('@')
  expect(await c.type('@')).toEqual({ text: '@', cursor: 1 })
  expect(await band($)).toBeUndefined()
})

test('typing filters and Enter inserts @<lane> at the cursor, sending nothing', async ($, on) => {
  await started($, on)
  const c = composer($, on)
  await c.type('ask ')
  await c.type('@')
  await c.type('b')
  await c.type('E')
  expect(await band($)).toMatchObject({ rows: ['> @beta', '@beta:hostone'] })
  const r = await c.enter()
  expect(r.drop).toBeDefined()
  expect(r.box).toEqual({ text: 'ask @beta ', cursor: 10 })
  expect(await band($)).toBeUndefined()
})

test('Enter after a start-of-box @ (the box is not empty) inserts the lane', async ($, on) => {
  await started($, on)
  const c = composer($, on)
  await c.type('@')
  await c.type('al')
  expect(c.box.text).toBe(`${MARK}al `)
  const r = await c.enter()
  expect(r.drop).toBe('lane picked')
  expect(r.box).toEqual({ text: '@alpha ', cursor: 7 })
  expect(await band($)).toBeUndefined()

  // A bare @ takes the top match too.
  const bare = composer($, on)
  await bare.type('@')
  expect((await bare.enter()).box.text).toBe('@alpha ')
})

test('Backspace takes the filter back a character at a time, then the @', async ($, on) => {
  await started($, on)
  const c = composer($, on)
  await c.type('@al')
  expect(await c.backspace()).toEqual({ text: `${MARK}a `, cursor: 2 })
  expect(await c.backspace()).toEqual({ text: `${MARK} `, cursor: 1 })
  expect(await band($)).toBeDefined()
  expect(await c.backspace()).toEqual({ text: '', cursor: 0 })
  expect(await band($)).toBeUndefined()
})

test('Enter keeps the text after the @ and a lane in the middle of a sentence', async ($, on) => {
  await started($, on)
  const c = composer($, on)
  await c.type('ask ')
  await c.type('@')
  await c.type('alpha:')
  expect((await c.enter()).box.text).toBe('ask @alpha:hostone ')

  // With the picker closed, Enter is an ordinary submit that names the lane.
  await c.type('now')
  const sent = await c.enter()
  expect(sent.drop).toBeUndefined()
  expect(sent.text).toBe('ask @alpha:hostone now')
  expect(sent.context?.[0]).toContain('@alpha:hostone')
})

test('Enter with no match gives back the @ and what was typed, and sends nothing', async ($, on) => {
  await started($, on)
  const c = composer($, on)
  await c.type('hi ')
  await c.type('@')
  await c.type('zzz')
  const r = await c.enter()
  expect(r.drop).toBeDefined()
  expect(r.box).toEqual({ text: 'hi @zzz', cursor: 7 })
  expect(await band($)).toBeUndefined()
})

test('a space cancels the picker and keeps the @ and what was typed', async ($, on) => {
  await started($, on)
  const c = composer($, on)
  await c.type('@')
  await c.type('al')
  expect(await c.type(' ')).toEqual({ text: '@al ', cursor: 4 })
  expect(await band($)).toBeUndefined()
})

test('with no lanes the @ goes on to the stock menu', async ($, on) => {
  await started($, on, '')
  const c = composer($, on)
  expect(await c.type('@')).toEqual({ text: '@', cursor: 1 })
  expect(await band($)).toBeUndefined()
})

test('the submit context names a mentioned lane and the text is untouched', async ($, on) => {
  await started($, on)
  const text = 'please ask @alpha, and @beta:nowhere, about it'
  const r = await $.prompt.submit({ text, wait: false, origin: { kind: 'composer' } })
  expect(r.text).toBe(text)
  expect(r.context).toHaveLength(1)
  expect(r.context?.[0]).toContain('@alpha')
  expect(r.context?.[0]).toContain('lane-mail.sh send --from @<your own lane> --to @<lane> --subject ... --body -')
  expect(r.context?.[0]).not.toContain('@beta')

  const plain = await $.prompt.submit({ text: 'no lanes here, mail me@alpha.example', wait: false, origin: { kind: 'composer' } })
  expect(plain.context).toBeUndefined()
})

test('the band lists the matches for the typed filter, best first', async ($, on) => {
  await started($, on)
  const c = composer($, on)
  await c.type('@')
  expect((await band($))?.rows).toEqual(['> @alpha', '@beta', '@alpha:hostone', '@beta:hostone'])
  await c.type('b')
  expect((await band($))?.rows).toEqual(['> @beta', '@beta:hostone'])
})

// The picker itself, edit by edit, with no engine: the cases a real terminal
// may deliver differently (a paste, an unusual key) and the stale-picker guard.
const lanes: Lane[] = parseLanes(LIST)
const e = (over: Partial<Edit>): Edit => ({ text: '', cursor: 0, start: 0, end: 0, inputText: '', ...over })

test('parseLanes orders live, mailbox, then peers, drops bad names', () => {
  expect(lanes.map(l => l.address)).toEqual(['@alpha', '@beta', '@alpha:hostone', '@beta:hostone'])
})

test('parseLanes lists remote lanes after mailbox lanes, once, and drops malformed ones', () => {
  const out = parseLanes('live\talpha\nremote\tbuilder:hostb\nremote\tbuilder:hostb\nremote\tBad:host\nremote\tnohost\nremote\ta:b:c\npeer\thostb\n')
  expect(out.map(l => l.address)).toEqual(['@alpha', '@builder:hostb', '@alpha:hostb'])
  expect(out[1]?.source).toBe('remote')
})

test('a remote lane from the thread store counts as known on submit', () => {
  const known = parseLanes('remote\tbuilder:hostb\n')
  expect(mentions('ask @builder:hostb, then @builder:other', known)).toEqual(['@builder:hostb'])
})

test('matchLanes puts prefix matches before substring matches', () => {
  const found = matchLanes([{ address: '@xalpha', source: 'live' }, { address: '@alpha', source: 'live' }], 'alp')
  expect(found.map(l => l.address)).toEqual(['@alpha', '@xalpha'])
})

test('a pasted word fills the filter; a pasted sentence is given back literally', () => {
  const p: LanePicker = { anchor: 0, text: '', filter: '' }
  const at = { text: `${MARK} `, cursor: 1, start: 1, end: 1 }
  expect(step(p, lanes, e({ ...at, inputText: 'alp' })).picker).toMatchObject({ filter: 'alp' })
  expect(step(p, lanes, e({ ...at, inputText: 'a b' })).box).toEqual({ text: '@a b', cursor: 4 })
})

test('Backspace trims the filter, then on an empty one drops the @', () => {
  const p: LanePicker = { anchor: 0, text: '', filter: 'a' }
  const trimmed = step(p, lanes, e({ key: { key: 'backspace' }, text: `${MARK}a `, cursor: 2, start: 1, end: 2 }))
  expect(trimmed.picker).toMatchObject({ filter: '' })
  expect(trimmed.box).toEqual({ text: `${MARK} `, cursor: 1 })
  const gone = step(trimmed.picker, lanes, e({ key: { key: 'backspace' }, text: `${MARK} `, cursor: 1, start: 0, end: 1 }))
  expect(gone).toEqual({ picker: null, box: { text: '', cursor: 0 } })
})

test('a picker opened on another text is stale and forgotten', () => {
  const p: LanePicker = { anchor: 0, text: 'old', filter: 'a' }
  expect(step(p, lanes, e({ text: 'new', cursor: 3, start: 3, end: 3, inputText: 'x' }))).toEqual({ picker: null })
})

test('finish takes the best match, or the typed text; the mention finder ignores files and email', () => {
  const p: LanePicker = { anchor: 3, text: 'hi  there', filter: 'be' }
  expect(finish(p, lanes)).toEqual({ text: 'hi @beta there', cursor: 8 })
  expect(finish({ anchor: 4, text: 'ask ', filter: 'al' }, lanes)).toEqual({ text: 'ask @alpha ', cursor: 11 })
  expect(finish({ ...p, filter: 'zzz' }, lanes)).toEqual({ text: 'hi @zzz there', cursor: 7 })
  expect(mentions('see @alpha.md and a@beta and @beta.', lanes)).toEqual(['@beta'])
})

// C-f / C-b: pick another entry than the top one.
const marked = async ($: any) => ((await band($))?.rows ?? []).find((r: string) => r.startsWith('>'))

test('C-f moves the highlight down and C-b up, clamped at both ends, and the box does not change', async ($, on) => {
  await started($, on)
  const c = composer($, on)
  await c.type('@')
  const before = { ...c.box }
  expect(await marked($)).toBe('> @alpha')
  expect(await c.ctrl('f')).toEqual(before)
  expect(await marked($)).toBe('> @beta')
  await c.ctrl('f')
  await c.ctrl('f')
  expect(await marked($)).toBe('> @beta:hostone')
  await c.ctrl('f') // the last row: no wrap
  expect(await marked($)).toBe('> @beta:hostone')
  await c.ctrl('b')
  expect(await marked($)).toBe('> @alpha:hostone')
  for (let i = 0; i < 5; i++) await c.ctrl('b')
  expect(await marked($)).toBe('> @alpha') // the first row: no wrap
  expect(c.box).toEqual(before)
})

test('Enter inserts the highlighted entry, at the start of the box and mid-sentence', async ($, on) => {
  await started($, on)
  const c = composer($, on)
  await c.type('@al')
  await c.ctrl('f')
  await c.ctrl('f') // one more than there are matches: stays on the last
  expect(await marked($)).toBe('> @alpha:hostone')
  await c.ctrl('b')
  await c.ctrl('f')
  const r = await c.enter()
  expect(r.drop).toBe('lane picked')
  expect(r.box).toEqual({ text: '@alpha:hostone ', cursor: 15 })

  const m = composer($, on)
  await m.type('ask ')
  await m.type('@')
  await m.ctrl('f')
  expect((await m.enter()).box).toEqual({ text: 'ask @beta ', cursor: 10 })
})

test('typing or trimming the filter puts the highlight back on the top match', async ($, on) => {
  await started($, on)
  const c = composer($, on)
  await c.type('@')
  await c.ctrl('f')
  await c.ctrl('f')
  expect(await marked($)).toBe('> @alpha:hostone')
  await c.type('a')
  expect(await marked($)).toBe('> @alpha')
  await c.ctrl('f')
  expect(await marked($)).toBe('> @alpha:hostone')
  await c.backspace()
  expect(await marked($)).toBe('> @alpha')
})

test('C-f and C-b pass through untouched while the picker is closed', async ($, on) => {
  await started($, on)
  const c = composer($, on)
  await c.type('hello')
  await c.ctrl('b')
  await c.ctrl('b')
  expect(c.box).toEqual({ text: 'hello', cursor: 3 })
  await c.ctrl('f')
  expect(c.box).toEqual({ text: 'hello', cursor: 4 })
  expect(await band($)).toBeUndefined()
})

test('the trailing space the picker adds never survives a way out of it', async ($, on) => {
  await started($, on)
  const c = composer($, on)

  await c.type('@al')
  expect(c.box).toEqual({ text: `${MARK}al `, cursor: 3 }) // the cursor sits before the space
  await c.type(' ')
  expect(c.box).toEqual({ text: '@al ', cursor: 4 }) // the typed space, not ours

  const m = composer($, on)
  await m.type('hi ')
  await m.type('@zz')
  expect((await m.enter()).box.text).toBe('hi @zz') // no match
  expect(m.box.text.endsWith(' ')).toBe(false)

  const b = composer($, on)
  await b.type('@')
  await b.backspace()
  expect(b.box).toEqual({ text: '', cursor: 0 })

  const at = composer($, on)
  await at.type('@')
  expect(await at.type('@')).toEqual({ text: '@', cursor: 1 })

  const e = composer($, on)
  await e.type('@b')
  await e.ctrl('f')
  expect((await e.enter()).box.text).toBe('@beta:hostone ') // the one space after a lane is Enter's, not ours
})

test('a cursor move or Ctrl key other than C-f / C-b cancels and leaves plain text', async ($, on) => {
  await started($, on)
  const c = composer($, on)
  await c.type('ask @al')
  const r = await $.prompt.edit({ text: c.box.text, cursor: c.box.cursor, start: c.box.cursor, end: c.box.cursor, key: { key: 'e', ctrl: true }, inputText: '', origin: { kind: 'composer' } })
  expect(r.text).toBe('ask @al')
  expect(await band($)).toBeUndefined()
})

test('plain takes out the mark and the space, and maps positions after the space', () => {
  const p: LanePicker = { anchor: 4, text: 'ask  now', filter: 'al' }
  expect(shown(p)).toEqual({ text: `ask ${MARK}al  now`, cursor: 7 })
  const q = plain(p, shown(p).text)
  expect(q.text).toBe('ask @al now')
  expect([q.at(7), q.at(8)]).toEqual([7, 7])
  expect(q.at(9)).toBe(8)
  // A box that lost the mark or the space is left as it is.
  expect(plain(p, 'ask  now').text).toBe('ask  now')
})
