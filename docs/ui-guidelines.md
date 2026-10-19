# UI interaction guidelines

Use Apple's [button guidance](https://developer.apple.com/design/human-interface-guidelines/buttons)
and [accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility).
Farcast uses compact native macOS controls. Safari is the reference for restrained
window chrome, normal body fonts and compact tabs. iPad/touch sizing is a separate
future design task; do not apply a 44-point touch baseline to the Mac interface.

- Prefer native bordered/primary buttons and regular control size. Do not add fixed
  padding or oversized fonts to native controls. Reuse IconActionButton (24 points)
  and PrimaryActionButton; icon buttons retain tooltips and accessibility labels.
- SSH, RDP and VNC icons use distinct SF Symbol shapes with semibold strokes and
  adaptive protocol colours: teal SSH, indigo RDP and orange VNC. Use darker shades
  in light mode, lighter shades in dark mode and stronger shades with Increase
  Contrast. Focused selected sidebar icons use a lighter or darker shade of the
  same hue, choosing the better contrast against the system selection colour;
  inactive selections use the normal palette. Icons have no separate background. Tabs,
  import previews and overview cards share the palette; colour is supplementary. Protocol names remain in
  accessibility labels and import previews. Target at least 3:1 icon/background
  contrast ([WCAG non-text contrast](https://www.w3.org/WAI/WCAG22/Understanding/non-text-contrast.html)).
- Session tabs are 28 points high with rounded top corners, an opaque selected fill
  and normal body text. Secondary session tools and editor tabs use a lighter
  underline style; keep a divider between the session and tool rows. Keep the independent 22-point close target
  visible, with its session name in help and accessibility. Announce protocol/state
  and selection; status never relies on colour alone.
- Use `SessionState.color` for connection indicators in the sidebar, tabs and
  session status bar: orange for waiting, connecting, verifying, authenticating,
  reconnecting and stale; green for connected; red for failed; grey for disconnected.
  A saved profile with no open session has no status dot. When several sessions
  share a profile, the sidebar represents a connected session first, then an active
  session, then the latest failure or disconnected session.
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
  720 points in a horizontally centered column with 24-point side padding and a
  32-point top inset. Keep the title, description and Add Tunnel action fixed across
  states. Use a full-width empty card with type-specific quick starts. Show Edit saved
  tunnels only when saved rules exist. Keep terminal and file surfaces full-width.
- Use native ToolbarItem/ToolbarItemGroup buttons with unframed Label content and
  system glass. Do not reuse fixed-size IconActionButton inside the native toolbar.
  Group Quick Connect, session actions (Reconnect/Disconnect), and view actions
  (Full Screen/Connection Details/Pop Out), with native fixed toolbar spacers.
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

- Terminal zoom and Find appear only in Terminal/Split View. Order zoom as minus,
  clickable reset percentage, plus, then labeled Find. Use compact elapsed time
  consistently (`47s`, `1:47`, `1h 02m`) and the active connection as the window title.
  Sidebar selection remains independent of the active tab.
