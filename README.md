<p align="center">
  <img src="assets/icon.png" width="128" height="128" alt="gsession icon">
</p>

<h1 align="center">gsession</h1>

<p align="center">
  <strong>Keep track of your GlobalProtect VPN session, right from the menu bar.</strong>
</p>

<p align="center">
  <a href="https://github.com/bzantium/globalsession/releases/latest"><img src="https://img.shields.io/github/v/release/bzantium/globalsession?label=Download" alt="Download"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-blue" alt="Platform">
  <img src="https://img.shields.io/github/license/bzantium/globalsession" alt="License">
</p>

---

gsession is a lightweight macOS menu bar utility that monitors your GlobalProtect VPN connection. It shows session time remaining, lets you switch SASE policy modes, and provides quick connect/disconnect/restart controls — all without opening the GlobalProtect app.

## Features

- **Session Countdown** — Live timer with a color-coded gradient progress bar (green → yellow → red)
- **Dev / Prod Mode Toggle** — Switch SASE policy mode instantly with animated wave transition
- **VPN Controls** — Connect, disconnect, or restart your VPN directly from the popover
- **Color-Coded Menu Bar Icon** — Blue for Dev, orange for Prod, monochrome when disconnected
- **Session Expiry Detection** — Automatically detects when your session expires and updates the UI
- **Launch at Login** — Starts automatically via macOS Login Items

## Install

### Homebrew (recommended)

```bash
brew tap bzantium/globalsession
brew install --cask globalsession
```

### Manual

Download the latest `.dmg` from [Releases](https://github.com/bzantium/globalsession/releases), open it, and drag **gsession** to Applications.

> **Note:** On first launch, right-click the app → Open → Open, since the app is not notarized.

## Requirements

- macOS Ventura (13.0) or later
- GlobalProtect VPN client installed
- Accessibility permission (required for VPN connect/disconnect controls)

## Build from Source

```bash
git clone https://github.com/bzantium/globalsession.git
cd globalsession
./scripts/dev.sh
```

Or build a DMG installer:

```bash
brew install create-dmg
./scripts/build-dmg.sh
```

## License

MIT
