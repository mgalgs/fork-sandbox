// The mod's $.state contract: the lane picker, null while it is closed.
export type LanePicker = {
  /** Where the picked address goes: the cursor when the picker opened. */
  anchor: number
  /** The box text the picker opened on, without the `@` and filter it shows in the box; a box other than the one shown means it is stale. */
  text: string
  /** What the operator has typed since the swallowed `@`; Enter takes the highlighted match of it. */
  filter: string
  /** The highlighted row among the visible matches (C-f down, C-b up); absent is the top one, and any change of the filter puts it back there. */
  index?: number
}

declare module 'claude-code' {
  interface PluginState {
    'lane-complete': { picker: LanePicker | null }
  }
}
