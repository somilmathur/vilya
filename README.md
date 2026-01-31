# Vilya

Persistent terminal sessions from your iPhone. SSH into your Mac from anywhere and pick up right where you left off.

![MIT License](https://img.shields.io/badge/license-MIT-blue.svg)
![macOS](https://img.shields.io/badge/macOS-12%2B-brightgreen)
![iOS](https://img.shields.io/badge/iOS-17%2B-brightgreen)

## What is this?

Vilya lets you run terminal sessions on your Mac that persist even when you disconnect. Start a long-running command, close the app, come back later - your session is still there.

Perfect for:
- Running Claude Code from your phone
- Long-running builds/deploys
- Working from anywhere via Tailscale

## Installation

### Mac (daemon)

```bash
brew install somilmathur/vilya/vilya
```

Then start the daemon:

```bash
vilya start
```

### iPhone (app)

Build from source (see below) or TestFlight link coming soon.

## Usage

### Daemon Commands

```bash
vilya start      # Start the daemon (runs in background)
vilya stop       # Stop the daemon
vilya status     # Show status and active sessions
vilya sessions   # List all sessions
vilya kill <n>   # Kill a specific session
```

### Connecting from iPhone

1. Make sure both devices are on [Tailscale](https://tailscale.com)
2. Enable Remote Login on your Mac (System Settings → General → Sharing → Remote Login)
3. Open Vilya app, enter your Tailscale IP and username
4. Create a session - it persists even when you disconnect!

## Architecture

```
┌─────────────────────┐                    ┌─────────────────────┐
│   iPhone (Vilya)    │                    │      Mac            │
│                     │                    │                     │
│  ┌───────────────┐  │   SSH + Tunnel     │  ┌───────────────┐  │
│  │  SwiftUI App  │──┼────────────────────┼──│  Vilya Daemon │  │
│  │  + SwiftTerm  │  │   via Tailscale    │  │  (port 17177) │  │
│  └───────────────┘  │                    │  └───────┬───────┘  │
│                     │                    │          │          │
└─────────────────────┘                    │  ┌───────▼───────┐  │
                                           │  │   PTY Shell   │  │
                                           │  │ (zsh + p10k)  │  │
                                           │  └───────────────┘  │
                                           └─────────────────────┘
```

Sessions survive disconnects because the daemon keeps the PTY alive.

## Building the iOS App

### Prerequisites

- Xcode 15.0+
- iOS 17.0+ device

### Steps

```bash
git clone https://github.com/somilmathur/vilya.git
cd vilya
open Vilya.xcodeproj
```

Select your development team in Signing & Capabilities, then build and run.

## Requirements

### Mac
- macOS 12+
- Python 3 (installed automatically by Homebrew)
- Remote Login enabled
- Tailscale (for remote access)

### iPhone
- iOS 17.0+
- Tailscale app (for remote access)

## Features

- **Persistent Sessions** - Sessions survive app close/disconnect
- **Scrollback Buffer** - See history when you reconnect
- **Syntax Highlighting** - zsh-syntax-highlighting support
- **Powerlevel10k** - Full p10k prompt support
- **Claude Code** - Works with Claude Code CLI

## License

MIT - see [LICENSE](LICENSE)

## Author

[Somil Mathur](https://twitter.com/somilmathur)
