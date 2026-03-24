<p align="center">
  <img src="assets/icon.png" width="128" height="128" alt="GlobalSession icon">
</p>

<h1 align="center">GlobalSession</h1>

<p align="center">
  macOS menu bar app for monitoring GlobalProtect VPN session status.
</p>

## Features

- **Session Timer** — Tracks your VPN session time with a countdown and progress bar
- **Status Indicator** — Green/red dot showing VPN connection state at a glance
- **Dev/Prod Mode Toggle** — Switch SASE policy mode directly from the menu bar
- **Alert Levels** — Color-coded warnings as your session approaches expiry

## Install

### Homebrew (recommended)

```bash
brew tap bzantium/globalsession
brew install --cask globalsession
```

### Manual

Download the latest DMG from [Releases](https://github.com/bzantium/globalsession/releases), open it, and drag GlobalSession to Applications.

> **Note:** This app is not code-signed. On first launch, right-click the app and select "Open", then click "Open" in the dialog.

## Build from Source

Requires Xcode 15+ and macOS Ventura (13.0) or later.

```bash
xcodebuild -project GlobalSession.xcodeproj \
  -scheme GlobalSession \
  -configuration Release \
  -destination 'platform=macOS' \
  build
```

To build a DMG installer:

```bash
brew install create-dmg
./scripts/build-dmg.sh
```

## How It Works

GlobalSession reads the GlobalProtect event log to detect VPN connect/disconnect events and calculates the remaining session time (9-hour sessions). It also communicates with a SASE policy API to display and switch between dev/prod modes.

## License

MIT
