// The lane-complete logic with no engine in it: parsing the lane list,
// filtering it, stepping the picker on one prompt.edit, and finding lane
// mentions in a submitted prompt. register.tsx wires these to the hooks; the
// tests drive them directly (prompt.edit has no call on the test's `$`).

import type { LanePicker } from '../types'

export type Lane = {
  /** The lane-mail address as it is typed: `@lane` or `@lane:host`. */
  address: string
  source: 'live' | 'mailbox' | 'peer'
}

/** The part of a prompt.edit input the picker reads. */
export type Edit = {
  key?: { key: string; ctrl?: true; shift?: true; meta?: true }
  text: string
  cursor: number
  start: number
  end: number
  inputText: string
}

/** What one edit did: the picker after it, and who answers the edit. */
export type Step = {
  picker: LanePicker | null
  /** Set: answer the edit with this box and never call `next` (the key is ours). */
  box?: { text: string; cursor: number }
  /** Set: pass the edit on to `next` as if typed into this box (the `@` of an `@@`). */
  replay?: { text: string; cursor: number; start: number; end: number }
}

/** How many matches the band shows at once. */
export const VISIBLE = 6

const NAME = /^[a-z0-9][a-z0-9.-]*$/
const FILTER_CHARS = /^[A-Za-z0-9:.-]+$/

/**
 * Parses list-lanes.sh output (`<source>\t<name>` lines) into addresses:
 * live lanes, then mailbox-only lanes, then each local lane qualified with
 * each peer host (the peers file names hosts, not their lanes, and a lane is
 * usually run on both ends of a link).
 */
export function parseLanes(stdout: string): Lane[] {
  const live: string[] = []
  const mailbox: string[] = []
  const peers: string[] = []
  for (const line of stdout.split('\n')) {
    const [source, name] = line.split('\t')
    if (name === undefined || !NAME.test(name)) continue
    if (source === 'live') live.push(name)
    else if (source === 'mailbox') mailbox.push(name)
    else if (source === 'peer') peers.push(name)
  }
  const lanes: Lane[] = []
  const seen = new Set<string>()
  const add = (address: string, source: Lane['source']) => {
    if (seen.has(address)) return
    seen.add(address)
    lanes.push({ address, source })
  }
  for (const name of live) add(`@${name}`, 'live')
  for (const name of mailbox) add(`@${name}`, 'mailbox')
  for (const name of [...live, ...mailbox]) {
    for (const peer of peers) add(`@${name}:${peer}`, 'peer')
  }
  return lanes
}

/** The lanes a typed filter leaves: prefix matches first, then substring ones. */
export function matchLanes(lanes: readonly Lane[], filter: string): Lane[] {
  const f = filter.toLowerCase()
  const prefix: Lane[] = []
  const inside: Lane[] = []
  for (const lane of lanes) {
    const name = lane.address.slice(1)
    if (name.startsWith(f)) prefix.push(lane)
    else if (name.includes(f)) inside.push(lane)
  }
  return [...prefix, ...inside]
}

function splice(text: string, at: number, insert: string) {
  return { text: text.slice(0, at) + insert + text.slice(at), cursor: at + insert.length }
}

/** A `@` typed here would be a mention, not the tail of an email address. */
function isWordStart(text: string, at: number): boolean {
  return at === 0 || /\s/.test(text.charAt(at - 1))
}

/** The row the picker has highlighted, kept inside the visible matches. */
export function highlighted(p: LanePicker, lanes: readonly Lane[], by = 0): number {
  const rows = Math.min(matchLanes(lanes, p.filter).length, VISIBLE)
  return Math.max(0, Math.min((p.index ?? 0) + by, rows - 1))
}

/** The box with the picker's choice at its anchor, in place of the `@` and filter; one space after it unless one follows. */
function accept(p: LanePicker, address: string) {
  const at = Math.min(p.anchor, p.text.length)
  const space = /\s/.test(p.text.charAt(at)) ? '' : ' '
  return splice(p.text, at, `${address}${space}`)
}

/**
 * What stands in the box for the `@` while the picker is open: a full-width
 * commercial at, which looks like one but is not one to Claude Code's own
 * `@` menu (an ASCII `@` in the box opens that menu over the picker).
 */
export const MARK = '\uFF20'

/**
 * The box while the picker is open: the mark and what was typed after it sit
 * in the text at the anchor, so the box is never empty (Claude Code fires no
 * submit and no Backspace edit for an empty one) and the operator sees what
 * they typed. `p.text` is the box without them.
 *
 * One space follows the filter, with the cursor before it: the editor emits
 * no edit for a cursor-forward that cannot move (the cursor at the box's end,
 * where it sits after a start-of-box `@al`), and C-f must always arrive. The
 * space is ours alone: `plain` takes it out again on every way out.
 */
export function shown(p: LanePicker) {
  const at = Math.min(p.anchor, p.text.length)
  return { text: splice(p.text, at, `${MARK}${p.filter} `).text, cursor: at + 1 + p.filter.length }
}

/** Where `shown` puts its space (the cursor sits here). */
function padAt(p: LanePicker): number {
  return Math.min(p.anchor, p.text.length) + 1 + p.filter.length
}

/**
 * A box as `shown` made it, as plain text: a real `@` where the mark is and
 * the space taken out, which is what any way out of the picker leaves. A
 * position in the shown box maps to `at(i)` here. A box that is not quite the
 * shown one (changed behind the picker) loses only the parts that are there.
 */
export function plain(p: LanePicker, text: string) {
  const anchor = Math.min(p.anchor, text.length)
  const pad = padAt(p)
  const marked = text.charAt(anchor) === MARK
  const unmarked = marked ? `${text.slice(0, anchor)}@${text.slice(anchor + 1)}` : text
  const padded = marked && text.charAt(pad) === ' '
  return {
    text: padded ? unmarked.slice(0, pad) + unmarked.slice(pad + 1) : unmarked,
    at: (i: number) => (padded && i > pad ? i - 1 : i),
  }
}

/**
 * The box an Enter pressed with the picker open leaves: the highlighted match
 * in place of the `@` and filter, or with none the `@` and filter as plain text.
 * The caller drops the submit and puts this box back.
 */
export function finish(p: LanePicker, lanes: readonly Lane[]) {
  const best = matchLanes(lanes, p.filter)[highlighted(p, lanes)]
  return best === undefined ? { text: plain(p, shown(p).text).text, cursor: shown(p).cursor } : accept(p, best.address)
}

/**
 * One prompt.edit through the picker. `picker` is null while closed. A closed
 * picker opens on a swallowed word-start `@` (only when there are lanes to
 * pick: with none, the `@` goes on to the stock menu), answering with the box
 * that has the `@` in it; an open one swallows every edit until it closes.
 *
 * Only keys the editor takes as an edit reach prompt.edit: Enter, Tab, Esc and
 * the arrows Up/Down never do, so none of them is handled here. Enter arrives
 * as a prompt.submit and is answered by `finish`.
 */
export function step(picker: LanePicker | null, lanes: readonly Lane[], e: Edit): Step {
  // A picker whose box is not the one shown is stale (the box was cleared or
  // changed behind it): forget it and treat this edit as one with no picker.
  if (picker !== null && shown(picker).text !== e.text) picker = null

  if (picker === null) {
    const isAt = e.inputText === '@' && e.start === e.end && isWordStart(e.text, e.start)
    if (!isAt || lanes.length === 0) return { picker: null }
    const opened = { anchor: e.start, text: e.text, filter: '' }
    return { picker: opened, box: shown(opened) }
  }

  const key = e.key
  const name = key !== undefined && key.key.length > 1 ? key.key : undefined
  const isMod = key !== undefined && (key.ctrl === true || key.meta === true)
  const open = (next: LanePicker): Step => ({ picker: next, box: shown(next) })
  // Closed with the box as the edit leaves it, `@` and filter kept as plain text.
  const close = (box: { text: string; cursor: number }): Step => ({ picker: null, box })

  // Backspace trims the filter; on an empty one it undoes the `@` itself.
  const isBackspace = name === 'backspace' || (name === undefined && e.inputText === '' && e.end > e.start && !isMod)
  if (isBackspace) {
    if (picker.filter === '') return close({ text: picker.text, cursor: Math.min(picker.anchor, picker.text.length) })
    return open({ anchor: picker.anchor, text: picker.text, filter: picker.filter.slice(0, -1) })
  }

  // C-f / C-b are the editor's cursor-forward/back, which would cancel the
  // picker; here they move the highlight (next / previous), clamped at both
  // ends, and the box is answered as shown so the cursor never moves.
  if (key !== undefined && key.ctrl === true && key.meta !== true && (key.key === 'f' || key.key === 'b')) {
    return open({ ...picker, index: highlighted({ ...picker, index: highlighted(picker, lanes) }, lanes, key.key === 'f' ? 1 : -1) })
  }

  // `@@`: a second `@` right after the swallowed one goes on to the stock
  // menu, as the one `@` it would have been: the edit is replayed on the box
  // without ours.
  if (e.inputText === '@' && picker.filter === '') {
    const at = Math.min(picker.anchor, picker.text.length)
    return { picker: null, replay: { text: picker.text, cursor: at, start: at, end: at } }
  }

  if (name === undefined && !isMod && FILTER_CHARS.test(e.inputText)) {
    return open({ anchor: picker.anchor, text: picker.text, filter: picker.filter + e.inputText.toLowerCase() })
  }

  // Anything else (a space, punctuation, a paste of prose, a cursor move, an
  // unknown key) is not a lane: the `@` and what was typed stay as plain text,
  // with the character typed after them.
  const kept = plain(picker, e.text)
  if (name === undefined && !isMod && e.inputText !== '') {
    const start = kept.at(e.start)
    const text = kept.text.slice(0, start) + e.inputText + kept.text.slice(kept.at(e.end))
    return close({ text, cursor: start + e.inputText.length })
  }
  return close({ text: kept.text, cursor: kept.at(e.cursor) })
}

/**
 * The known lanes a submitted prompt mentions, in order of first mention.
 * A mention is a whole `@lane` or `@lane:host` word (a trailing sentence
 * mark is allowed) that is in the lane list: an `@file.ts` or an email
 * address is never one.
 */
export function mentions(text: string, lanes: readonly Lane[]): string[] {
  const known = new Set(lanes.map(l => l.address))
  const found: string[] = []
  const re = /(?:^|\s)(@[a-z0-9][a-z0-9.-]*(?::[a-z0-9][a-z0-9.-]*)?)(?=[.,;:!?)\]"']*(?:\s|$))/g
  for (const m of text.matchAll(re)) {
    // The pattern is greedy over dots and a sentence-final one is not part of the name.
    const address = (m[1] ?? '').replace(/[.]+$/, '')
    if (known.has(address) && !found.includes(address)) found.push(address)
  }
  return found
}

/** The note the model reads beside a prompt that mentions lanes. */
export function mentionContext(addresses: readonly string[]): string {
  const list = addresses.join(', ')
  return [
    `The operator's prompt mentions lane-mail ${addresses.length === 1 ? 'lane' : 'lanes'}: ${list}.`,
    'Those are lane-mail addresses (an agent session\'s mailbox), not files or agents.',
    'A lane can be messaged with:',
    '  lane-mail.sh send --from @<your own lane> --to @<lane> --subject ... --body -',
    '(message body on stdin; `lane-mail.sh registration` prints your own lane; `@lane:host` is a lane on another host).',
    'Decide from the prompt\'s wording whether the operator wants a message sent or is only referring to the lane; send nothing unless they asked.',
  ].join('\n')
}
