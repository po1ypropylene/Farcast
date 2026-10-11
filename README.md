# Farcast

<img src="docs/images/Farcast-Icon.png" alt="Farcast app icon" width="128" height="128">

A native Mac workspace for SSH terminals, SFTP file transfers and RDP desktops.
Keep saved connections and active sessions together in a tabbed SwiftUI interface.

- **SSH & SFTP:** password, private-key or interactive sign-in; terminal and files share one connection.
- **Remote Desktop:** RDP with full-screen/multiple-monitor and Retina options, optional text/file clipboard, selected local folder drives and remote sound.
- **Private servers:** optional embedded WireGuard connections for RDP.
- **Local storage:** saved profiles and credentials stay on your Mac.

Requires **macOS 27 or later and Apple silicon**. Protocol libraries are bundled;
users don't need Homebrew or a separate SSH, RDP or WireGuard client.
This is an early preview. Local builds use Apple Development signing and are unnotarized.

## Screenshots

![Farcast workspace and saved connections](docs/images/Farcast-Home.png)

**SSH terminal**

![SSH terminal and connection tabs](docs/images/Farcast-SSH.png)

**SFTP file transfer**

![Local and remote SFTP file panels](docs/images/Farcast-SFTP.png)

**Remote desktop**

![RDP desktop session](docs/images/Farcast-RDP.png)

**Connection editor**

![Connection settings and WireGuard selection](docs/images/Farcast-EditConnection.png)

## Get started

Open Farcast, choose **SSH Terminal**, **Remote Desktop**, or **Quick Connect**,
and enter your server details. Verify an unfamiliar server fingerprint before signing in.
Save a profile for later or use Quick Connect for a single session.
See the [user guide](docs/user-guide.md) for file transfers, settings and shortcuts.
To bring an earlier library into Farcast, use **File → Import Existing Library…**;
see [migration instructions](docs/user-guide.md#move-an-existing-library-to-farcast).

Credentials use Keychain when available. The development fallback stores them in
owner-only, **unencrypted local files**; saving screens explain this choice.

## Build from source

Install Xcode with the macOS SDK and Metal compiler, Git, CMake, Python 3 and Go 1.27+.
The first dependency build needs internet access. Install an Apple Development
certificate in Xcode → Settings → Accounts → Manage Certificates before building.

```sh
brew install cmake  # If needed
xcodebuild -downloadComponent MetalToolchain  # If Xcode reports it missing
scripts/prepare-dependencies.sh
scripts/build.sh
open ".build/Xcode/Build/Products/Release/Farcast.app"
```

Or prepare dependencies, open `Farcast.xcodeproj`, and Run. Allow the pinned
SwiftTerm build plugin if Xcode requests approval.
Dependency caches live in `.dependencies`, installed native libraries in `Vendor/Native`,
and disposable outputs in `.build`. You can clear `.build` between builds.

## More information

[Development & releases](docs/development.md) · [Testing](docs/testing.md) ·
[Architecture](docs/architecture.md) · [WireGuard](docs/wireguard.md) ·
[Changelog](CHANGELOG.md) ·
[Validation & known limits](docs/validation.md) · [Agent guide](AGENTS.md)

Dependency versions and licenses are in [ThirdParty](ThirdParty/README.md).
The license for Farcast's own source is still undecided.
