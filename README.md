# Vilya

An iPhone app that lets you SSH into your laptop and use Claude Code from anywhere.

## Features

- **Multiple Terminal Sessions** - Run several SSH sessions simultaneously
- **SSH from Any Network** - Uses Tailscale mesh VPN for secure access anywhere
- **Secure Authentication** - SSH key-only auth (no passwords)
- **File Browser** - Browse and transfer files via SFTP
- **Session Persistence** - tmux integration keeps sessions alive
- **Command Notifications** - Get notified when long-running commands complete

## Architecture

```
┌─────────────────────┐                    ┌─────────────────────┐
│   iPhone (Vilya)    │                    │   Laptop (macOS)    │
│                     │                    │                     │
│  ┌───────────────┐  │    SSH (port 22)   │  ┌───────────────┐  │
│  │  SwiftUI App  │◄─┼───────────────────►│  │   sshd        │  │
│  │  + NMSSH      │  │   over Tailscale   │  └───────┬───────┘  │
│  │  + SwiftTerm  │  │   (100.x.x.x)      │          │          │
│  └───────────────┘  │                    │  ┌───────▼───────┐  │
│                     │                    │  │ tmux + Claude │  │
└─────────────────────┘                    │  │     Code      │  │
                                           │  └───────────────┘  │
                                           └─────────────────────┘
```

**No bridge server required** - the app connects directly to your laptop via SSH.

## Requirements

### iPhone
- iOS 17.0+
- Tailscale app installed

### Laptop (macOS)
- macOS with SSH enabled (System Preferences → Sharing → Remote Login)
- Tailscale installed and running
- tmux installed (`brew install tmux`)

## Setup

### 1. Install Tailscale on Both Devices

**On your Mac:**
```bash
brew install tailscale
tailscale up
tailscale ip -4  # Note this IP (e.g., 100.100.100.1)
```

**On your iPhone:**
- Install Tailscale from the App Store
- Log in with the same account

### 2. Install tmux (Optional but Recommended)

```bash
brew install tmux
```

### 3. Configure SSH Key

When you first launch Vilya, it will generate an SSH key pair. Copy the public key and add it to your laptop:

```bash
echo "ssh-ed25519 AAAA... vilya-iphone" >> ~/.ssh/authorized_keys
```

### 4. Connect

1. Open Vilya on your iPhone
2. Enter your Tailscale IP, username, and port (22)
3. Tap Connect
4. Start using Claude Code!

## Building the App

### Prerequisites

- Xcode 15.0+
- CocoaPods (`sudo gem install cocoapods`)

### Steps

1. Clone the repository:
```bash
git clone <repo-url>
cd vilya/Vilya
```

2. Install dependencies:
```bash
pod install
```

3. Open the workspace:
```bash
open Vilya.xcworkspace
```

4. Select your development team in Xcode and build

## Tech Stack

- **SwiftUI** - UI framework
- **NMSSH** - SSH/SFTP client library
- **SwiftTerm** - Terminal emulator (via Swift Package Manager)
- **CryptoKit** - SSH key generation
- **Tailscale** - Mesh VPN networking

## Project Structure

```
Vilya/
├── App/
│   ├── VilyaApp.swift          # App entry point
│   └── ContentView.swift       # Root navigation
├── Features/
│   ├── Connection/             # Server setup & connection
│   ├── Terminal/               # Terminal sessions
│   ├── Files/                  # SFTP file browser
│   └── Settings/               # App settings
├── Services/
│   ├── SSHService.swift        # NMSSH wrapper
│   ├── KeychainService.swift   # Secure key storage
│   ├── TmuxService.swift       # tmux integration
│   └── NotificationService.swift
├── Models/
│   ├── Server.swift
│   ├── TerminalSession.swift
│   └── FileItem.swift
└── Utilities/
    ├── SSHKeyGenerator.swift   # Ed25519 key generation
    └── Constants.swift
```

## Security

1. **Network Layer**: Tailscale encrypts all traffic with WireGuard
2. **Authentication**: Ed25519 SSH keys stored in iOS Keychain
3. **No Passwords**: Key-only authentication, no password storage

## License

MIT
