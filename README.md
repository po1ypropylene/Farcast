# Farcast

<img src="docs/images/Farcast-Icon.png" alt="Farcast app icon" width="128" height="128">

SSH terminals, SFTP files and RDP/VNC desktops in one native Mac app.
Includes saved connections, session tabs, SSH tunnels and optional shared WireGuard for SSH, RDP and VNC.

Farcast is free and open source under the [MIT License](LICENSE): free to download,
use, modify and redistribute. Retain the copyright and license notice.
[Bundled dependencies](ThirdParty/README.md) retain their own licenses.

Requires **macOS 27+ and Apple silicon**. Protocol libraries are bundled.
Local builds are Apple Development signed and unnotarized.
Credentials use Keychain when available; the development fallback uses
owner-only, **unencrypted local files**.

## Screenshots

![Farcast workspace and saved connections](docs/images/Farcast-Home.png)

**SSH terminal**

![SSH terminal and connection tabs](docs/images/Farcast-SSH.png)

**SFTP file transfer**

![Local and remote SFTP file panels](docs/images/Farcast-SFTP.png)

**Remote desktop display settings**

<img src="docs/images/Farcast-RDP.png" alt="Remote desktop resolution and Retina settings" width="540">

**Connection editor**

<img src="docs/images/Farcast-EditConnection.png" alt="Tabbed connection editor and sign-in settings" width="540">

## Build

With Xcode and the [build prerequisites](docs/development.md#build-from-source) installed:

```sh
scripts/prepare-dependencies.sh
scripts/build.sh
open ".build/Xcode/Build/Products/Release/Farcast.app"
```

[User guide](docs/user-guide.md) · [Development](docs/development.md) ·
[Agent guide](AGENTS.md) · [Architecture](docs/architecture.md) ·
[Testing](docs/testing.md) · [Known limits](docs/validation.md) ·
[Changelog](CHANGELOG.md) · [Dependencies & licenses](ThirdParty/README.md)
