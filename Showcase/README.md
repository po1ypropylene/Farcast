# Screenshot app

Build a separate app using Farcast's current native interface and local simulated
sessions. No server, VPN service or saved credential is needed. All library edits
and credentials are in memory and reset when the app quits. The separate bundle
identifier `com.peterpo.farcast.showcase` isolates preferences and sandbox storage
from the normal app. The visible name and interface remain Farcast.

```sh
Showcase/build.sh
open .build/Xcode/Build/Products/Release/Farcast-demo.app
```

The build reuses the pinned certificate and native dependencies. It increments the build
number in `Version.xcconfig` for each app build, keeping the marketing version.
The output sits beside `Farcast.app`; the normal app is never replaced. The DMG
script stages only `Farcast.app` and excludes this app.

Double-click any saved connection. SSH renders terminal output locally and echoes
typed input, with a fixed response on Enter. The Archives connection opens Files;
other SSH connections support Terminal, Files and Split using the same session.
SFTP shows synthetic listings on both sides and supports folder navigation and
filtering; file contents and transfers are not implemented. RDP and VNC render
original static desktop artwork through the app's existing Metal renderer. VPN
profiles appear in the standard library and attached sessions display Ready without
starting a helper. Desktop input does not control a remote system.

For repeatable screenshot setups, quit this app between launches and choose:

```sh
open .build/Xcode/Build/Products/Release/Farcast-demo.app --args --showcase-view=ssh
# Also: files, rdp, vnc, vpn
```

Edit `catalog.json` for connections and VPN metadata, `Session.swift` for terminal
content, `Files.swift` for directory listings, and `ShowcaseDesktop.swift` for the
original desktop artwork. Use reserved `.example` hosts. No external artwork is
required. README screenshots are not modified by the build.

`prepare.py` copies app sources/project into ignored `.build/showcase-source`, then
applies checked source replacements and adds these support files there. Production
sources/project contain no showcase paths, runtime switch or conditional feature.
Source changes that invalidate a patch fail the build and require reviewing this
integration. Never add these support files under the production `Farcast` folder.

`verify.py` applies the standard bundle, signing, loader and synthetic helper checks
to the separate identity, exercises the seeded sessions and lifecycle, and scans an
existing production bundle for showcase symbols/data. The helper checks use owned
loopback fixtures; screenshot sessions themselves use no networking. This does not
establish real protocol interoperability. Run `python3 -m unittest discover -s
Showcase -p 'test_*.py' -v` to check source isolation and generated integration.
