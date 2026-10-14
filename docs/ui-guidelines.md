# UI interaction guidelines

Use Apple's [button guidance](https://developer.apple.com/design/human-interface-guidelines/buttons)
and [accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility).
Farcast uses compact native macOS controls. Safari is the reference for restrained
window chrome, normal body fonts and compact tabs. iPad/touch sizing is a separate
future design task; do not apply a 44-point touch baseline to the Mac interface.

- Prefer native bordered/primary buttons and regular control size. Do not add fixed
  padding or oversized fonts to native controls. Reuse IconActionButton (24 points)
  and PrimaryActionButton; icon buttons retain tooltips and accessibility labels.
- Session tabs are 28 points high with normal body text and a selected underline.
  Use the same underline style for session tools and connection editor tabs. Keep the independent 22-point close target
  visible, with its session name in help and accessibility. Announce protocol/state
  and selection; status never relies on colour alone.
- Keep sizing and contentShape within custom labels so their visible region is
  clickable. Preserve keyboard focus, shortcuts and native accessibility behavior.
  Avoid overlapping hit regions, hidden measuring labels and forced shrinking.
- The connection editor uses pinned text tabs with a selected underline and one body
  scroll view. Header/tab bar/actions stay fixed. Use bordered fields, a shared
  128-point label column and a 12-point gap. Address and port share a row; resolution
  units stay inside the fields' row. Short captions sit beneath their controls and
  longer explanations use tooltips. Keep visible keyboard focus and announce invalid
  tabs as well as marking them visually. Keep new forms quiet until a required
  field is skipped or Save is attempted. New tunnel fields validate after editing
  and leaving them, or Save. Show errors once inline and only an issue-count footer.
- Saved/live tunnel cards fill their container at every type. Use shared form
  constants and 64-point ports; empty listen ports display Auto. Cap live cards at
  640 points with a consistent 24-point left inset. Center the empty state within
  that container; keep terminal and file surfaces at their useful viewport sizes.
- Group toolbar controls by purpose, label Quick Connect, and separate Disconnect.
  Toolbar commands have menu items and shortcuts. Confirm interruption only when
  file work or tunnels are active. Show sidebar state with accessible labels and
  uptime; keep only the protocol icon and omit marketing taglines.
- Disclosure headers elsewhere activate across their full row and announce state.
- Use normal list rows and 24-point local/server headings/navigation controls, with
  matching file-panel heights. The Local Mac heading opens the folder picker.
  File-only SSH disables unavailable terminal modes and tools.
- Keep transfer cancellation separate from destructive confirmations. Inspect text
  wrapping, disabled state, tooltips and keyboard navigation with synthetic data.
  Full VoiceOver coverage needs separate verification.
