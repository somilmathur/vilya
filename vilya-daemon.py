#!/usr/bin/env python3
"""
Vilya - Persistent terminal sessions that just work.

Usage:
    vilya start      Start the daemon
    vilya stop       Stop the daemon gracefully
    vilya status     Show daemon status and active sessions
    vilya sessions   List all sessions (alias for 'list')
    vilya list       List all sessions
    vilya create <n> Create a new session
    vilya attach <n> Attach to a session
    vilya kill <n>   Kill a session

Options:
    -v, --version    Show version
    -h, --help       Show this help
"""

VERSION = "0.1.1"

import os
import sys
import pty
import socket
import select
import signal
import json
import threading
import subprocess
from pathlib import Path
from collections import deque

# Configuration
SOCKET_DIR = Path("/tmp/vilya")
PID_FILE = SOCKET_DIR / "vilya.pid"
BUFFER_SIZE = 100 * 1024  # 100KB scrollback per session
CHUNK_SIZE = 4096
TCP_PORT = 17177  # TCP port for SSH tunnel connections (in addition to Unix socket)

class Session:
    def __init__(self, name: str):
        self.name = name
        self.master_fd = None
        self.pid = None
        self.buffer = deque(maxlen=BUFFER_SIZE)
        self.clients = []  # List of connected client sockets
        self.lock = threading.Lock()
        self.running = False

    def start(self):
        """Start the shell process with a PTY."""
        pid, master_fd = pty.fork()

        if pid == 0:
            # Child process - exec the shell
            os.environ['TERM'] = 'xterm-256color'
            # Mark this as a Vilya session so zshrc can skip problematic integrations
            os.environ['VILYA_SESSION'] = '1'
            # Start zsh with a custom init that loads user's config but skips problematic integrations
            os.execlp('/bin/zsh', 'zsh', '-c', '''
                # Load PATH from standard locations (works on both macOS Intel and ARM)
                export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin:$HOME/.cargo/bin"

                # Source conda (check common locations)
                for conda_sh in \
                    "/opt/homebrew/Caskroom/miniconda/base/etc/profile.d/conda.sh" \
                    "$HOME/miniconda3/etc/profile.d/conda.sh" \
                    "$HOME/anaconda3/etc/profile.d/conda.sh" \
                    "/usr/local/Caskroom/miniconda/base/etc/profile.d/conda.sh"; do
                    [ -f "$conda_sh" ] && . "$conda_sh" && break
                done

                # NVM (check common locations)
                export NVM_DIR="$HOME/.nvm"
                for nvm_sh in \
                    "/opt/homebrew/opt/nvm/nvm.sh" \
                    "/usr/local/opt/nvm/nvm.sh" \
                    "$NVM_DIR/nvm.sh"; do
                    [ -s "$nvm_sh" ] && . "$nvm_sh" && break
                done

                # pyenv
                command -v pyenv >/dev/null && eval "$(pyenv init -)"

                # Create a minimal zshrc that loads essentials but skips problematic integrations
                export ZDOTDIR=$(mktemp -d)
                cat > "$ZDOTDIR/.zshrc" << 'ZSHRC'
# Vilya session zshrc - minimal config that avoids problematic integrations

# Oh My Zsh (if installed)
if [ -d "$HOME/.oh-my-zsh" ]; then
    export ZSH="$HOME/.oh-my-zsh"
    # Use powerlevel10k if installed, otherwise default theme
    if [ -d "$ZSH/custom/themes/powerlevel10k" ]; then
        ZSH_THEME="powerlevel10k/powerlevel10k"
    fi
    plugins=(git)
    source "$ZSH/oh-my-zsh.sh"
fi

# Common aliases
alias ll='ls -lah'
alias la='ls -la'
alias l='ls -l'

# FZF
[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# Syntax highlighting (if installed)
for hl in \
    "$HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" \
    "/opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" \
    "/usr/local/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"; do
    [ -f "$hl" ] && source "$hl" && break
done

# Autosuggestions (if installed)
for as in \
    "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" \
    "/opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh" \
    "/usr/local/share/zsh-autosuggestions/zsh-autosuggestions.zsh"; do
    [ -f "$as" ] && source "$as" && break
done

# Powerlevel10k config
[ -f ~/.p10k.zsh ] && source ~/.p10k.zsh
ZSHRC

                # Start in home directory (safer default)
                cd "$HOME"

                # Now start interactive zsh with our custom ZDOTDIR
                exec zsh -i
            ''')
        else:
            # Parent process
            self.pid = pid
            self.master_fd = master_fd
            self.running = True

            # Start reader thread
            self.reader_thread = threading.Thread(target=self._read_loop, daemon=True)
            self.reader_thread.start()

    def _read_loop(self):
        """Read from PTY and distribute to clients + buffer."""
        while self.running:
            try:
                r, _, _ = select.select([self.master_fd], [], [], 0.1)
                if self.master_fd in r:
                    data = os.read(self.master_fd, CHUNK_SIZE)
                    if not data:
                        self.running = False
                        break

                    with self.lock:
                        # Add to buffer
                        self.buffer.extend(data)

                        # Send to all connected clients
                        dead_clients = []
                        for client in self.clients:
                            try:
                                client.sendall(data)
                            except:
                                dead_clients.append(client)

                        for client in dead_clients:
                            self.clients.remove(client)
            except OSError:
                self.running = False
                break

    def attach(self, client_socket):
        """Attach a client to this session."""
        with self.lock:
            # Send buffered history first
            history = bytes(self.buffer)
            if history:
                try:
                    client_socket.sendall(history)
                except:
                    return False

            self.clients.append(client_socket)
        return True

    def detach(self, client_socket):
        """Detach a client from this session."""
        with self.lock:
            if client_socket in self.clients:
                self.clients.remove(client_socket)

    def write(self, data: bytes):
        """Write data to the PTY (from client input)."""
        if self.master_fd and self.running:
            try:
                os.write(self.master_fd, data)
            except OSError:
                pass

    def resize(self, rows: int, cols: int):
        """Resize the PTY."""
        if self.master_fd:
            import fcntl
            import struct
            import termios
            winsize = struct.pack('HHHH', rows, cols, 0, 0)
            fcntl.ioctl(self.master_fd, termios.TIOCSWINSZ, winsize)

    def kill(self):
        """Kill the session."""
        self.running = False
        if self.pid:
            try:
                os.kill(self.pid, signal.SIGTERM)
            except:
                pass


class Daemon:
    def __init__(self):
        self.sessions = {}
        self.control_socket = None
        self.tcp_socket = None
        self.running = False
        SOCKET_DIR.mkdir(exist_ok=True)

    def start(self):
        """Start the daemon."""
        control_path = SOCKET_DIR / "control.sock"

        # Check if daemon is already running
        if PID_FILE.exists():
            try:
                pid = int(PID_FILE.read_text().strip())
                os.kill(pid, 0)  # Check if process exists
                print(f"Daemon already running (PID {pid})")
                sys.exit(1)
            except (ProcessLookupError, ValueError):
                # Stale PID file, remove it
                PID_FILE.unlink()

        # Remove stale socket
        if control_path.exists():
            control_path.unlink()

        # Write PID file
        PID_FILE.write_text(str(os.getpid()))

        # Unix socket for local connections
        self.control_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.control_socket.bind(str(control_path))
        self.control_socket.listen(5)

        # TCP socket for SSH tunnel connections (binds to localhost only for security)
        self.tcp_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.tcp_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.tcp_socket.bind(('127.0.0.1', TCP_PORT))
        self.tcp_socket.listen(5)

        self.running = True

        # Handle SIGTERM for graceful shutdown
        def handle_sigterm(signum, frame):
            self.running = False
        signal.signal(signal.SIGTERM, handle_sigterm)

        print(f"Vilya daemon started (PID {os.getpid()})")
        print(f"  Unix socket: {control_path}")
        print(f"  TCP port: {TCP_PORT}")

        while self.running:
            try:
                r, _, _ = select.select([self.control_socket, self.tcp_socket], [], [], 1.0)
                for sock in r:
                    client, _ = sock.accept()
                    threading.Thread(target=self._handle_client, args=(client,), daemon=True).start()
            except KeyboardInterrupt:
                break

        self._cleanup()

    def _handle_client(self, client):
        """Handle a client connection."""
        try:
            # Read command
            data = client.recv(CHUNK_SIZE)
            if not data:
                return

            cmd = json.loads(data.decode())
            action = cmd.get('action')

            if action == 'list':
                sessions = [{'name': s.name, 'running': s.running} for s in self.sessions.values()]
                client.sendall(json.dumps({'sessions': sessions}).encode())
                client.close()

            elif action == 'create':
                name = cmd.get('name')
                if name in self.sessions:
                    client.sendall(json.dumps({'error': 'Session exists'}).encode())
                else:
                    session = Session(name)
                    session.start()
                    self.sessions[name] = session
                    client.sendall(json.dumps({'ok': True}).encode())
                client.close()

            elif action == 'attach':
                name = cmd.get('name')
                session = self.sessions.get(name)

                if not session:
                    # Auto-create session if it doesn't exist
                    session = Session(name)
                    session.start()
                    self.sessions[name] = session

                # Handle resize if provided
                rows = cmd.get('rows', 24)
                cols = cmd.get('cols', 80)
                session.resize(rows, cols)

                # For direct socket connections (no CLI wrapper), skip OK response
                # The client will immediately start receiving PTY data
                skip_ok = cmd.get('direct', False)
                if not skip_ok:
                    client.sendall(json.dumps({'ok': True}).encode() + b'\n')

                # Attach client
                if session.attach(client):
                    self._proxy_client(client, session)
                    session.detach(client)

            elif action == 'kill':
                name = cmd.get('name')
                session = self.sessions.get(name)
                if session:
                    session.kill()
                    del self.sessions[name]
                    client.sendall(json.dumps({'ok': True}).encode())
                else:
                    client.sendall(json.dumps({'error': 'Session not found'}).encode())
                client.close()

            elif action == 'resize':
                name = cmd.get('name')
                session = self.sessions.get(name)
                if session:
                    session.resize(cmd.get('rows', 24), cmd.get('cols', 80))
                    client.sendall(json.dumps({'ok': True}).encode())
                else:
                    client.sendall(json.dumps({'error': 'Session not found'}).encode())
                client.close()

            else:
                client.sendall(json.dumps({'error': 'Unknown action'}).encode())
                client.close()

        except Exception as e:
            print(f"Client error: {e}")
            try:
                client.close()
            except:
                pass

    def _proxy_client(self, client, session):
        """Proxy data between client and session."""
        client.setblocking(False)

        while session.running:
            try:
                r, _, _ = select.select([client], [], [], 0.1)
                if client in r:
                    data = client.recv(CHUNK_SIZE)
                    if not data:
                        break
                    session.write(data)
            except:
                break

    def _cleanup(self):
        """Clean up on exit."""
        print("\nShutting down...")
        for name, session in self.sessions.items():
            print(f"  Killing session: {name}")
            session.kill()
        if self.control_socket:
            self.control_socket.close()
        if self.tcp_socket:
            self.tcp_socket.close()
        control_path = SOCKET_DIR / "control.sock"
        if control_path.exists():
            control_path.unlink()
        if PID_FILE.exists():
            PID_FILE.unlink()
        print("Daemon stopped.")


def client_command(action: str, **kwargs):
    """Send a command to the daemon."""
    control_path = SOCKET_DIR / "control.sock"

    if not control_path.exists():
        print("Daemon not running. Start with: vilya-daemon.py start")
        sys.exit(1)

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(str(control_path))

    cmd = {'action': action, **kwargs}
    sock.sendall(json.dumps(cmd).encode())

    if action == 'attach':
        raw_mode = kwargs.pop('raw_mode', False)

        # Read OK response (with timeout)
        sock.settimeout(5.0)
        try:
            response = b''
            while b'\n' not in response:
                chunk = sock.recv(1)
                if not chunk:
                    print("Connection closed by daemon")
                    sock.close()
                    return
                response += chunk
        except socket.timeout:
            print("Timeout waiting for daemon response")
            sock.close()
            return

        sock.settimeout(None)

        # Check if response indicates error
        try:
            resp_json = json.loads(response.strip())
            if 'error' in resp_json:
                print(f"Error: {resp_json['error']}")
                sock.close()
                return
        except:
            pass

        stdin_fd = sys.stdin.fileno()
        stdout_fd = sys.stdout.fileno()
        sock.setblocking(False)

        if raw_mode:
            # Raw mode - no tty manipulation, just proxy data
            # Used when running inside another PTY (like SSH from Vilya)
            while True:
                try:
                    r, _, _ = select.select([stdin_fd, sock], [], [], 0.5)
                except select.error:
                    break

                if stdin_fd in r:
                    try:
                        data = os.read(stdin_fd, CHUNK_SIZE)
                        if not data:
                            break
                        sock.sendall(data)
                    except OSError:
                        break

                if sock in r:
                    try:
                        data = sock.recv(CHUNK_SIZE)
                        if not data:
                            break
                        os.write(stdout_fd, data)
                    except BlockingIOError:
                        continue
                    except OSError:
                        break
        else:
            # Normal mode - set up raw terminal for local use
            import tty
            import termios
            old_settings = termios.tcgetattr(sys.stdin)

            try:
                tty.setraw(sys.stdin.fileno())

                while True:
                    try:
                        r, _, _ = select.select([stdin_fd, sock], [], [], 0.5)
                    except select.error:
                        break

                    if stdin_fd in r:
                        try:
                            data = os.read(stdin_fd, CHUNK_SIZE)
                            if not data:
                                break
                            if b'\x1d' in data:  # Ctrl+] to detach
                                break
                            sock.sendall(data)
                        except OSError:
                            break

                    if sock in r:
                        try:
                            data = sock.recv(CHUNK_SIZE)
                            if not data:
                                break
                            os.write(stdout_fd, data)
                        except BlockingIOError:
                            continue
                        except OSError:
                            break

            except Exception as e:
                pass
            finally:
                termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
                print("\r\n[Detached - press Ctrl+] to detach next time]")
    else:
        response = sock.recv(CHUNK_SIZE)
        print(response.decode())

    sock.close()


def direct_attach(name: str, rows: int, cols: int):
    """Direct attach mode - pure I/O proxy without any tty manipulation.

    Used when called from SSH exec (no shell wrapper), where the caller
    handles all terminal setup. Just connects to daemon and proxies stdio.
    """
    control_path = SOCKET_DIR / "control.sock"

    if not control_path.exists():
        sys.stderr.write("Daemon not running\n")
        sys.exit(1)

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(str(control_path))

    # Send attach command with direct flag (no JSON response)
    cmd = {'action': 'attach', 'name': name, 'rows': rows, 'cols': cols, 'direct': True}
    sock.sendall(json.dumps(cmd).encode())

    # Set non-blocking for select
    sock.setblocking(False)
    stdin_fd = sys.stdin.fileno()
    stdout_fd = sys.stdout.fileno()

    # Pure proxy loop - no tty manipulation
    try:
        while True:
            r, _, _ = select.select([stdin_fd, sock], [], [], 1.0)

            if stdin_fd in r:
                try:
                    data = os.read(stdin_fd, CHUNK_SIZE)
                    if not data:
                        break
                    sock.sendall(data)
                except OSError:
                    break

            if sock in r:
                try:
                    data = sock.recv(CHUNK_SIZE)
                    if not data:
                        break
                    os.write(stdout_fd, data)
                except BlockingIOError:
                    continue
                except OSError:
                    break
    except KeyboardInterrupt:
        pass
    except Exception:
        pass
    finally:
        sock.close()


def get_daemon_status():
    """Check if daemon is running and return status info."""
    if not PID_FILE.exists():
        return None, None

    try:
        pid = int(PID_FILE.read_text().strip())
        os.kill(pid, 0)  # Check if process exists
        return pid, True
    except (ProcessLookupError, ValueError):
        return None, False


def stop_daemon():
    """Stop the running daemon."""
    pid, running = get_daemon_status()

    if not running:
        if pid is None:
            print("Daemon is not running")
        else:
            print("Daemon is not running (stale PID file)")
            PID_FILE.unlink()
        return

    print(f"Stopping daemon (PID {pid})...")
    try:
        os.kill(pid, signal.SIGTERM)
        # Wait for process to exit
        import time
        for _ in range(30):  # Wait up to 3 seconds
            time.sleep(0.1)
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                print("Daemon stopped.")
                return
        print("Daemon did not stop gracefully, sending SIGKILL...")
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        print("Daemon stopped.")


def show_status():
    """Show daemon status and sessions."""
    pid, running = get_daemon_status()

    if not running:
        print("Vilya daemon: not running")
        if PID_FILE.exists():
            PID_FILE.unlink()
        return

    print(f"Vilya daemon: running (PID {pid})")
    print(f"  TCP port: {TCP_PORT}")
    print(f"  Socket: {SOCKET_DIR / 'control.sock'}")
    print()

    # Get session list
    try:
        control_path = SOCKET_DIR / "control.sock"
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(str(control_path))
        sock.sendall(json.dumps({'action': 'list'}).encode())
        response = json.loads(sock.recv(CHUNK_SIZE).decode())
        sock.close()

        sessions = response.get('sessions', [])
        if sessions:
            print(f"Sessions ({len(sessions)}):")
            for s in sessions:
                status = "running" if s['running'] else "stopped"
                print(f"  - {s['name']} ({status})")
        else:
            print("Sessions: none")
    except Exception as e:
        print(f"Could not get sessions: {e}")


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ['-h', '--help']:
        print(__doc__)
        sys.exit(0)

    if sys.argv[1] in ['-v', '--version']:
        print(f"vilya {VERSION}")
        sys.exit(0)

    action = sys.argv[1]

    if action == 'start':
        # Check if already running
        pid, running = get_daemon_status()
        if running:
            print(f"\033[33m⚠\033[0m  Vilya daemon already running (PID {pid})")
            sys.exit(1)

        # Fork to background
        pid = os.fork()
        if pid > 0:
            # Parent process - wait briefly for daemon to start, then show message
            import time
            time.sleep(0.3)

            # Check if daemon started successfully
            new_pid, running = get_daemon_status()
            if running:
                print()
                print(f"  \033[32m✓\033[0m  \033[1mVilya daemon started\033[0m")
                print(f"     PID: {new_pid}")
                print(f"     Port: {TCP_PORT}")
                print()
                print(f"     \033[90mRun '\033[0mvilya status\033[90m' to see sessions\033[0m")
                print(f"     \033[90mRun '\033[0mvilya stop\033[90m' to stop the daemon\033[0m")
                print()
            else:
                print("\033[31m✗\033[0m  Failed to start daemon")
                sys.exit(1)
            sys.exit(0)
        else:
            # Child process - become daemon
            os.setsid()  # Create new session
            # Redirect stdout/stderr to /dev/null
            sys.stdout = open('/dev/null', 'w')
            sys.stderr = open('/dev/null', 'w')
            daemon = Daemon()
            daemon.start()

    elif action == 'stop':
        stop_daemon()

    elif action == 'status':
        show_status()

    elif action in ['list', 'sessions']:
        client_command('list')

    elif action == 'create':
        if len(sys.argv) < 3:
            print("Usage: vilya-daemon.py create <name>")
            sys.exit(1)
        client_command('create', name=sys.argv[2])

    elif action == 'attach':
        if len(sys.argv) < 3:
            print("Usage: vilya-daemon.py attach <name> [--raw] [--rows N] [--cols N]")
            sys.exit(1)
        # Check for --raw flag (used when running inside another PTY)
        raw_mode = '--raw' in sys.argv
        # Get terminal size - allow override via args
        import shutil
        cols, rows = shutil.get_terminal_size()
        # Parse --rows and --cols if provided
        for i, arg in enumerate(sys.argv):
            if arg == '--rows' and i + 1 < len(sys.argv):
                rows = int(sys.argv[i + 1])
            elif arg == '--cols' and i + 1 < len(sys.argv):
                cols = int(sys.argv[i + 1])
        client_command('attach', name=sys.argv[2], rows=rows, cols=cols, raw_mode=raw_mode)

    elif action == 'attach-direct':
        # Direct attach mode - for use from SSH exec (no shell)
        # Reads JSON config from stdin, then proxies I/O to daemon
        if len(sys.argv) < 3:
            print("Usage: vilya-daemon.py attach-direct <name> <rows> <cols>")
            sys.exit(1)
        name = sys.argv[2]
        rows = int(sys.argv[3]) if len(sys.argv) > 3 else 24
        cols = int(sys.argv[4]) if len(sys.argv) > 4 else 80
        # Connect directly to daemon socket and proxy I/O
        # This mode is raw - no tty manipulation, just pure I/O proxying
        direct_attach(name, rows, cols)

    elif action == 'kill':
        if len(sys.argv) < 3:
            print("Usage: vilya-daemon.py kill <name>")
            sys.exit(1)
        client_command('kill', name=sys.argv[2])

    else:
        print(f"Unknown command: {action}")
        print("Run 'vilya --help' for usage")
        sys.exit(1)


if __name__ == '__main__':
    main()
