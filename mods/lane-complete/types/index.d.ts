// The mod's $.state contract: the lane picker, null while it is closed.
export type LanePicker = {
  /** Where the picked address goes: the cursor when the picker opened. */
  anchor: number
  /** The box text the picker opened on; a different text means it is stale. */
  text: string
  /** What the operator has typed since the swallowed `@`; Enter takes its best match. */
  filter: string
}

declare module 'claude-code' {
  interface PluginState {
    'lane-complete': { picker: LanePicker | null }
  }
}
