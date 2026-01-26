#!/usr/bin/env python3
"""
Vilya Session Daemon - Persistent terminal sessions with scrollback buffer.

Usage:
    Start daemon:   vilya-daemon.py start
    List sessions:  vilya-daemon.py list
    Create session: vilya-daemon.py create <name>
    Attach session: vilya-daemon.py attach <name>
    Kill session:   vilya-daemon.py kill <name>
"""

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
BUFFER_SIZE = 100 * 1024  # 100KB scrollback per session
CHUNK_SIZE = 4096

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
            shell = os.environ.get('SHELL', '/bin/zsh')
            os.execlp(shell, shell, '-l')
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
        self.running = False
        SOCKET_DIR.mkdir(exist_ok=True)

    def start(self):
        """Start the daemon."""
        control_path = SOCKET_DIR / "control.sock"

        # Remove stale socket
        if control_path.exists():
            control_path.unlink()

        self.control_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.control_socket.bind(str(control_path))
        self.control_socket.listen(5)
        self.running = True

        print(f"Vilya daemon started. Control socket: {control_path}")

        while self.running:
            try:
                r, _, _ = select.select([self.control_socket], [], [], 1.0)
                if self.control_socket in r:
                    client, _ = self.control_socket.accept()
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

                # Send OK, then switch to raw PTY mode
                client.sendall(json.dumps({'ok': True}).encode() + b'\n')

                # Handle resize if provided
                rows = cmd.get('rows', 24)
                cols = cmd.get('cols', 80)
                session.resize(rows, cols)

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
        for session in self.sessions.values():
            session.kill()
        if self.control_socket:
            self.control_socket.close()
        control_path = SOCKET_DIR / "control.sock"
        if control_path.exists():
            control_path.unlink()


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
        import tty
        import termios

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

        # Save terminal settings
        old_settings = termios.tcgetattr(sys.stdin)

        try:
            # Set terminal to raw mode
            tty.setraw(sys.stdin.fileno())

            # Make socket non-blocking
            sock.setblocking(False)

            stdin_fd = sys.stdin.fileno()
            stdout_fd = sys.stdout.fileno()

            while True:
                try:
                    r, _, _ = select.select([stdin_fd, sock], [], [], 0.5)
                except select.error:
                    break

                # Handle stdin -> socket
                if stdin_fd in r:
                    try:
                        data = os.read(stdin_fd, CHUNK_SIZE)
                        if not data:
                            break
                        # Check for Ctrl+] to detach (like telnet)
                        if b'\x1d' in data:
                            break
                        sock.sendall(data)
                    except OSError:
                        break

                # Handle socket -> stdout
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
            # Restore terminal settings
            termios.tcsetattr(sys.stdin, termios.TCSADRAIN, old_settings)
            print("\r\n[Detached - press Ctrl+] to detach next time]")
    else:
        response = sock.recv(CHUNK_SIZE)
        print(response.decode())

    sock.close()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    action = sys.argv[1]

    if action == 'start':
        daemon = Daemon()
        daemon.start()

    elif action == 'list':
        client_command('list')

    elif action == 'create':
        if len(sys.argv) < 3:
            print("Usage: vilya-daemon.py create <name>")
            sys.exit(1)
        client_command('create', name=sys.argv[2])

    elif action == 'attach':
        if len(sys.argv) < 3:
            print("Usage: vilya-daemon.py attach <name>")
            sys.exit(1)
        # Get terminal size
        import shutil
        cols, rows = shutil.get_terminal_size()
        client_command('attach', name=sys.argv[2], rows=rows, cols=cols)

    elif action == 'kill':
        if len(sys.argv) < 3:
            print("Usage: vilya-daemon.py kill <name>")
            sys.exit(1)
        client_command('kill', name=sys.argv[2])

    else:
        print(f"Unknown action: {action}")
        print(__doc__)
        sys.exit(1)


if __name__ == '__main__':
    main()
