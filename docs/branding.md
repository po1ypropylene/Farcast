# Farcast identity

The official app name is **Farcast**. The sidebar header, alerts, permission text,
macOS app menus, Xcode project/target/source folder and the built `Farcast.app` use
that spelling. The workspace window title shows the active connection, or Workspace
when no session is selected. The Swift module is `Farcast`, the core package/product is
`farcast-core` (Swift target `FarcastCore`), and the embedded executable is
`FarcastWireGuard` (shared by both VPN engines; retained for signing continuity). Package identifiers use lowercase:
`com.peterpo.farcast`, `com.peterpo.farcast.credentials`,
`com.peterpo.farcast.wireguard` and Go module `com.peterpo.farcast/vpn`.
Scripts resolve the outer repository root from their own paths, so its folder
and Git repository can be renamed independently.

Farcast uses its own macOS sandbox and credential namespace. Imported source
data stays untouched. **File → Import Existing Library…** explicitly imports a
user-selected prior library into an empty Farcast library, preserving profile,
folder and WireGuard IDs and metadata. Copying local credentials requires opt-in;
Keychain items are never exported/copied. Existing Keychain credentials must be
entered again, and app-specific folder grants need reselection. Historical identity
strings exist only in migration input recognition and regression fixtures.
See [the migration workflow](user-guide.md#move-an-existing-library-to-farcast).

After renaming the outer checkout, follow the cache relocation instructions in [development](development.md), then run `scripts/build.sh` to rebuild. Compiler caches and native install prefixes retain absolute checkout paths. Keep `.local-testing` intact. The already packaged app is self-contained and keeps working after a folder move.

## Icon direction

The supplied `farcast-logo-v5.svg` defines the monitor-and-broadcast artwork,
with an indigo background and a warm orange-to-pink screen. Preserve the received
SVG, including its provenance metadata. The sidebar uses a monochrome outline of
the same monitor, stand and broadcast symbol so native tint remains legible.

The editable app icon is a native Icon Composer document at
`Farcast/AppIcon.icon`. Its background, stand, monitor and broadcast symbol are
separate layers. The background canvas is unmasked; macOS supplies the outline,
depth, lighting and appearance variants. Colors and SVG geometry are retained,
while materials and appearance effects remain editable in Icon Composer.
Design references: [Apple app icon guidelines](https://developer.apple.com/design/human-interface-guidelines/app-icons/)
and [Icon Composer workflow](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer).

Run `scripts/update-icon-artwork.sh` to regenerate layer PNGs and the sidebar glyph
from the SVG using AppKit's native SVG renderer in `scripts/generate-icon.swift`.
The script preserves the Icon Composer document's material settings. If the supplied
SVG structure changes, review the layer split before regeneration. Run
`scripts/export-icon.sh` for Default, Dark, Mono and small-size previews. Generated
previews live under `.build` and are not app runtime assets.

Keep the README screenshot files, order, captions and markup unchanged unless
explicitly asked to update them. The README's 512×512 icon PNG uses the Default
macOS appearance of
`Farcast/AppIcon.icon`. Regenerate
`docs/images/Farcast-Icon.png` with `scripts/export-icon.sh --readme` after
editing the icon. The README displays it at 128×128; the Icon Composer document
remains the source of truth.
