# Vilya Roadmap

## Vision
A CLI tool + iOS app for persistent terminal sessions that "just works".

```bash
brew install vilya
vilya start
# Scan QR code from iOS app to connect
```

---

## Phase 1: CLI Tool

### Core Commands
- `vilya start` - Start daemon, display QR code for pairing
- `vilya stop` - Stop daemon gracefully
- `vilya status` - Show daemon status and active sessions
- `vilya sessions` - List all sessions
- `vilya kill <session>` - Kill a specific session

### QR Code Pairing
QR code encodes connection info:
```
vilya://connect?host=<tailscale-ip>&port=22&user=<username>&token=<pairing-token>
```

Contents:
- Auto-detected Tailscale IP (fallback to local IP)
- SSH port (default 22)
- Current username
- Optional: one-time pairing token for security

### Technical Decisions
- **Language**: Rust or Go (single binary, easy distribution)
- **Distribution**: Homebrew, apt, direct download
- **Config location**: `~/.config/vilya/`
- **Socket/Port**: Unix socket + TCP 17177 (like current)

### Auto-detection
- Detect Tailscale IP via `tailscale ip -4`
- Detect local network IP as fallback
- Detect current username

---

## Phase 2: iOS App Improvements

### QR Code Scanner
- Add camera permission
- Scan `vilya://` URLs
- Auto-configure server from QR data

### URL Scheme
Register `vilya://` URL scheme:
- `vilya://connect?host=...&port=...&user=...` - Add new server
- `vilya://session?name=...` - Connect to specific session

### Session Management
- Kill sessions from app (send `{"action": "kill", "name": "..."}`)
- Show session metadata (created time, last activity)
- Pull-to-refresh session list

### UI Polish
- Better onboarding for first-time users
- Connection status indicators
- Error messages that actually help

---

## Phase 3: Cross-Platform Daemon

### Linux Support
- Same daemon code, packaged for Linux
- Install script for remote servers
- `vilya install-remote user@server` command

### Server Management
- Multiple servers in iOS app
- Quick-switch between servers
- Per-server session lists

---

## Phase 4: Advanced Features

### Security
- SSH key generation in-app
- Secure key storage (Keychain)
- Optional: pairing tokens with expiry

### Terminal Features
- Fix resize propagation to daemon PTY
- Fix Claude Code rendering issues (mode 2026, etc.)
- Scrollback search
- Copy/paste improvements

### Sync
- iCloud sync for server configs
- Export/import configurations

---

## Ideas Parking Lot
(Add future ideas here)

-
-
-

---

## Current Status

### Working
- [x] SSH connection via Tailscale
- [x] Persistent sessions via daemon
- [x] DirectTCPIP tunnel (bypasses shell buffering)
- [x] Syntax highlighting in sessions
- [x] P10k prompt support
- [x] Claude Code runs without crashing (filtered mode 2026)

### Known Issues
- [ ] Terminal resize not propagated to daemon PTY (causes Claude rendering issues)
- [ ] Daemon needs Full Disk Access when run via launchd
- [ ] Some escape sequences not fully supported by SwiftTerm

### Next Up
- [ ] Kill sessions from iOS app
- [ ] CLI tool prototype
