# GlobalSession - GlobalProtect Session Monitor

## Project Overview
macOS menu bar app that monitors GlobalProtect VPN session status, displays session timer, and supports dev/prod mode switching.

## Architecture
```
UI (MenuBarPopover) → ViewModel → SessionManager (timer) + PolicyService (status/mode)
                                  └→ LogParser (GP event log)
```

## Key Files
- `GlobalSession/App/AppDelegate.swift` — NSStatusBar + NSPanel setup
- `GlobalSession/Views/MenuBarPopover.swift` — SwiftUI popover UI
- `GlobalSession/ViewModels/MenuBarViewModel.swift` — State management, polling
- `GlobalSession/Services/SessionManager.swift` — Session timer from log
- `GlobalSession/Services/LogParser.swift` — Parses GP event log for session times
- `GlobalSession/Services/PolicyService.swift` — SASE policy API calls
- `GlobalSession/Models/VPNState.swift` — Connection state, policy mode, session info models
- `GlobalSession/App/AppConstants.swift` — URLs, timeouts, durations

## Build & Install
```bash
# Quick build + install + launch
killall GlobalSession 2>/dev/null; xcodebuild -project GlobalSession.xcodeproj -scheme GlobalSession -configuration Debug -destination 'platform=macOS' build && rm -rf /Applications/GlobalSession.app && cp -R ~/Library/Developer/Xcode/DerivedData/GlobalSession-*/Build/Products/Debug/GlobalSession.app /Applications/ && open /Applications/GlobalSession.app

# Build DMG installer
./scripts/build-dmg.sh
```

## API Endpoints
- `GET https://selka.onkakao.net/sase/policy` — Check VPN status + policy mode
- `POST https://selka.onkakao.net/sase/prod` — Switch to prod mode
- `POST https://selka.onkakao.net/sase/default` — Switch to dev mode

## GP Log File
- Path: `/Library/Logs/PaloAltoNetworks/GlobalProtect/pan_gp_event.log`
- Connect pattern: `portal status is Connected`
- Disconnect pattern: `Tunnel is down due to disconnection`
- Session duration: 9 hours
