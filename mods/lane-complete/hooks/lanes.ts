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

/** The box with the picker's choice at its anchor; one space after it unless one follows. */
function accept(p: LanePicker, text: string, address: string) {
  const at = Math.min(p.anchor, text.length)
  const space = /\s/.test(text.charAt(at)) ? '' : ' '
  return splice(text, at, `${address}${space}`)
}

/** The box with what the operator typed put in as plain text: `@` and the filter. */
function literal(p: LanePicker, text: string, extra = '') {
  return splice(text, Math.min(p.anchor, text.length), `@${p.filter}${extra}`)
}

/**
 * The box an Enter pressed with the picker open leaves: the best match at the
 * anchor, or what was typed as plain text when nothing matches. The picker
 * swallowed the typed characters, so the submitted `text` has none of them;
 * the caller drops the submit and puts this box back (a submit also trims
 * the box's ends, which `finish` undoes where it can).
 */
export function finish(p: LanePicker, lanes: readonly Lane[], submitted: string) {
  // A submit trims the box ("ask " arrives as "ask"), which would put the
  // anchor past its end: the text the picker opened on is the truer base then.
  const text = submitted.trim() === p.text.trim() ? p.text : submitted
  const best = matchLanes(lanes, p.filter)[0]
  return best === undefined ? literal(p, text) : accept(p, text, best.address)
}

/**
 * One prompt.edit through the picker. `picker` is null while closed. A closed
 * picker opens on a swallowed word-start `@` (only when there are lanes to
 * pick: with none, the `@` goes on to the stock menu); an open one swallows
 * every edit until it closes.
 *
 * Only keys the editor takes as an edit reach prompt.edit: Enter, Tab, Esc and
 * the arrows Up/Down never do, so none of them is handled here. Enter arrives
 * as a prompt.submit and is answered by `finish`.
 */
export function step(picker: LanePicker | null, lanes: readonly Lane[], e: Edit): Step {
  // A picker opened on another text is stale (the box was cleared or changed
  // behind it): forget it and treat this edit as one with no picker.
  if (picker !== null && picker.text !== e.text) picker = null

  if (picker === null) {
    const isAt = e.inputText === '@' && e.start === e.end && isWordStart(e.text, e.start)
    if (!isAt || lanes.length === 0) return { picker: null }
    const opened = { anchor: e.start, text: e.text, filter: '' }
    return { picker: opened, box: { text: e.text, cursor: e.cursor } }
  }

  const key = e.key
  const name = key !== undefined && key.key.length > 1 ? key.key : undefined
  const isMod = key !== undefined && (key.ctrl === true || key.meta === true)
  const keep = (next: LanePicker) => ({ picker: next, box: { text: e.text, cursor: e.cursor } })
  const close = (box?: { text: string; cursor: number }): Step => ({
    picker: null,
    box: box ?? { text: e.text, cursor: e.cursor },
  })

  // Backspace trims the filter; on an empty one it undoes the `@` itself.
  const isBackspace = name === 'backspace' || (name === undefined && e.inputText === '' && e.end > e.start && !isMod)
  if (isBackspace) {
    if (picker.filter === '') return close()
    return keep({ ...picker, filter: picker.filter.slice(0, -1) })
  }

  // `@@`: a second `@` right after the swallowed one goes on to the stock menu.
  if (e.inputText === '@' && picker.filter === '') return { picker: null }

  if (name === undefined && !isMod && FILTER_CHARS.test(e.inputText)) {
    return keep({ ...picker, filter: picker.filter + e.inputText.toLowerCase() })
  }

  // Anything else (a space, punctuation, a paste of prose, an unknown key)
  // is not a lane: give the operator back what they typed, as plain text.
  if (name === undefined && !isMod && e.inputText !== '') return close(literal(picker, e.text, e.inputText))
  return close(literal(picker, e.text))
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
