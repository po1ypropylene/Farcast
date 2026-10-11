# UI interaction guidelines

Use Apple's [button guidance](https://developer.apple.com/design/human-interface-guidelines/buttons)
and [accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility).
Farcast uses compact native macOS controls. Safari is the reference for restrained
window chrome, normal body fonts and compact tabs. iPad/touch sizing is a separate
future design task; do not apply a 44-point touch baseline to the Mac interface.

- Prefer native bordered/primary buttons and regular control size. Do not add fixed
  padding or oversized fonts to native controls. Reuse IconActionButton (24 points)
  and PrimaryActionButton; icon buttons retain tooltips and accessibility labels.
- Session tabs are 28 points high with normal body text. Unselected tabs use clear
  glass; selection has a subtle tint. Keep the independent 22-point close target
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
  tabs as well as marking them visually.
- Disclosure headers elsewhere activate across their full row and announce state.
- Use normal list rows and 24-point local/server headings/navigation controls, with
  matching file-panel heights. The Local Mac heading opens the folder picker.
  File-only SSH disables unavailable terminal modes and tools.
- Keep transfer cancellation separate from destructive confirmations. Inspect text
  wrapping, disabled state, tooltips and keyboard navigation with synthetic data.
  Full VoiceOver coverage needs separate verification.
