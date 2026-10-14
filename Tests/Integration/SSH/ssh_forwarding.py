"""Owned loopback peers; never reads real input or executes remote shell commands."""
import concurrent.futures
import json
import os
from pathlib import Path
import queue
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid

root = Path(sys.argv[1])
binary = sys.argv[2]
server_port = int(sys.argv[3])
mode = sys.argv[4]


class Peer:
    def __init__(self, family=socket.AF_INET, early_eof=False):
        self.socket = socket.socket(family)
        self.socket.bind(('::1' if family == socket.AF_INET6 else '127.0.0.1', 0))
        self.socket.listen(64)
        self.socket.settimeout(.2)
        self.port = self.socket.getsockname()[1]
        self.early_eof = early_eof
        self.received = queue.Queue()
        self.stopped = threading.Event()
        self.connections = []
        self.thread = threading.Thread(target=self.accept, daemon=True)
        self.thread.start()

    def accept(self):
        while not self.stopped.is_set():
            try:
                peer, _ = self.socket.accept()
                self.connections.append(peer)
                threading.Thread(target=self.serve, args=(peer,), daemon=True).start()
            except socket.timeout:
                pass
            except OSError:
                break

    def serve(self, peer):
        data = bytearray()
        try:
            if self.early_eof:
                peer.sendall(b'EARLY-EOF'); peer.shutdown(socket.SHUT_WR)
            while True:
                block = peer.recv(16384)
                if not block:
                    break
                data.extend(block)
                if not self.early_eof:
                    peer.sendall(block)
            if not self.early_eof:
                peer.sendall(b'TAIL'); peer.shutdown(socket.SHUT_WR)
            self.received.put(bytes(data))
        except OSError:
            pass
        finally:
            peer.close()

    def close(self):
        self.stopped.set(); self.socket.close()
        for peer in self.connections:
            try: peer.close()
            except OSError: pass
        self.thread.join(timeout=2)


def rule(kind, destination, bind='127.0.0.1', port=0, enabled=True):
    return dict(id=str(uuid.uuid4()).upper(), kind=kind, bind=bind, port=port,
                host='127.0.0.1', destinationPort=destination, enabled=enabled)


class Client:
    def __init__(self, rules):
        self.process = subprocess.Popen([binary, str(server_port), str(root)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        self.events = []
        self.condition = threading.Condition()
        self.thread = threading.Thread(target=self.read, daemon=True); self.thread.start()
        self.send(dict(rules=rules))
        self.wait(lambda event: event.get('event') == 'status' and event.get('state') in ('connected', 'failed'))

    def read(self):
        for line in self.process.stdout:
            event = json.loads(line)
            with self.condition:
                self.events.append(event); self.condition.notify_all()

    def send(self, command):
        self.process.stdin.write(json.dumps(command) + '\n'); self.process.stdin.flush()

    def wait(self, predicate, timeout=20, after=0):
        end = time.monotonic() + timeout
        with self.condition:
            while True:
                for event in self.events[after:]:
                    if predicate(event): return event
                remaining = end - time.monotonic()
                if remaining <= 0:
                    raise AssertionError('Timed out waiting for a synthetic event: ' + repr(self.events[after:][-12:]))
                self.condition.wait(min(remaining, .2))

    def listener(self, config):
        return self.wait(lambda event: event.get('event') == 'rule' and event.get('id') == config['id'] and event.get('state') == 'listening')['port']

    def stop(self, config):
        after = len(self.events); self.send(dict(op='stop', id=config['id']))
        status = self.wait(lambda e: e.get('event') == 'rule' and e.get('id') == config['id'] and e.get('state') == 'stopped', after=after)
        assert status['port'] == 0, 'Stopped rule retained a bound port'

    def start(self, config):
        after = len(self.events); self.send(dict(op='start', id=config['id']))
        return self.wait(lambda e: e.get('event') == 'rule' and e.get('id') == config['id'] and e.get('state') == 'listening', after=after)['port']

    def close(self):
        if self.process.poll() is None:
            self.send(dict(op='quit')); self.process.stdin.close()
        try:
            self.process.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.process.kill(); self.process.wait(); raise AssertionError('Native worker did not drain')
        self.thread.join(timeout=2)
        assert self.process.returncode == 0, 'Native teardown failed'
        assert any(e.get('event') == 'drained' for e in self.events), 'Missing worker drain'


def check(condition, label):
    assert condition, label
    print('PASS SSH forwarding ' + label, flush=True)


def receive_exact(peer, count):
    data = bytearray()
    while len(data) < count:
        block = peer.recv(count - len(data))
        if not block: raise AssertionError('Unexpected EOF')
        data.extend(block)
    return bytes(data)


def exchange(port, data, family=socket.AF_INET, connected=None):
    peer = connected or socket.socket(family)
    peer.settimeout(20)
    if connected is None: peer.connect(('::1' if family == socket.AF_INET6 else '127.0.0.1', port))
    failure = []
    def send():
        try: peer.sendall(data); peer.shutdown(socket.SHUT_WR)
        except OSError as error: failure.append(error)
    sender = threading.Thread(target=send); sender.start()
    result = bytearray()
    while True:
        block = peer.recv(32768)
        if not block: break
        result.extend(block)
    sender.join(timeout=20); peer.close()
    assert not failure and not sender.is_alive(), 'Sender failed or stalled'
    assert result == data + b'TAIL', 'Byte mismatch or missing half-close tail'


def socks_connect(port, destination_port, host='127.0.0.1', atyp=1, fragmented=False):
    peer = socket.create_connection(('127.0.0.1', port), timeout=20)
    greeting = b'\x05\x02\x02\x00'
    for part in ([bytes([b]) for b in greeting] if fragmented else [greeting]):
        peer.sendall(part)
        if fragmented: time.sleep(.01)
    assert receive_exact(peer, 2) == b'\x05\x00'
    address = socket.inet_pton(socket.AF_INET if atyp == 1 else socket.AF_INET6, host) if atyp in (1, 4) else bytes([len(host.encode())]) + host.encode()
    request = b'\x05\x01\x00' + bytes([atyp]) + address + struct.pack('!H', destination_port)
    for part in ([bytes([b]) for b in request] if fragmented else [request]):
        peer.sendall(part)
        if fragmented: time.sleep(.005)
    assert receive_exact(peer, 10)[:4] == b'\x05\x00\x00\x01'
    return peer


peers = []
clients = []
try:
    target = Peer(); peers.append(target)
    local = rule('local', target.port)
    proxy = rule('socks', 0)
    remote = rule('remote', target.port)
    disabled = rule('local', target.port, enabled=False)
    occupied = socket.socket(); occupied.bind(('127.0.0.1', 0)); occupied.listen(1)
    collision = rule('local', target.port, port=occupied.getsockname()[1])
    denied = rule('remote', target.port, bind='0.0.0.0')
    client = Client([local, proxy, remote, disabled, collision, denied]); clients.append(client)
    if mode == 'forward-timeout':
        lp = client.listener(local)
        pending = socket.create_connection(('127.0.0.1', lp), timeout=10)
        pending.sendall(b'pending-open')
        failure = client.wait(lambda e: e.get('event') == 'status' and e.get('state') == 'failed', timeout=30)
        check(failure.get('stage') == 'tunnel', 'pending-open-timeout-fails-transport-with-redacted-reason')
        pending.close(); client.close(); clients.remove(client)
        check(True, 'pending-open-timeout-drains-workers')
    elif mode == 'forward-denied':
        client.wait(lambda e: e.get('id') == remote['id'] and e.get('state') == 'failed')
        lp = client.listener(local)
        failed = socket.create_connection(('127.0.0.1', lp), timeout=10); failed.settimeout(10)
        try: check(failed.recv(1) == b'', 'channel-policy-denial')
        finally: failed.close()
        check(True, 'remote-policy-denial')
        client.close(); clients.remove(client)
    else:
        lp, pp, rp = [client.listener(config) for config in (local, proxy, remote)]
        check(all(port > 0 for port in (lp, pp, rp)), 'reported-dynamic-listen-ports')
        client.wait(lambda e: e.get('id') == collision['id'] and e.get('state') == 'failed')
        client.wait(lambda e: e.get('id') == denied['id'] and e.get('state') == 'failed')
        check(True, 'bind-collision-and-remote-policy-errors')
        data = bytes(range(256)) * 4096
        exchange(lp, data); check(True, 'local-binary-equality-and-half-close-tail')
        exchange(rp, data); check(True, 'remote-binary-equality-and-half-close-tail')
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda _: exchange(lp, data[:262144]), range(8)))
        check(True, 'simultaneous-channels-and-serialized-open-retries')
        exchange(pp, data, connected=socks_connect(pp, target.port, fragmented=True))
        check(True, 'fragmented-socks-greeting-and-request')
        exchange(pp, data, connected=socks_connect(pp, target.port, host='only-on-server.invalid', atyp=3))
        check(True, 'socks-domain-resolves-only-on-server')
        ipv6 = Peer(socket.AF_INET6); peers.append(ipv6)
        exchange(pp, data, connected=socks_connect(pp, ipv6.port, host='::1', atyp=4))
        ipv6_rule = rule('local', target.port, bind='::1')
        check(True, 'socks-ipv6-destination')
        for command, reply in ((2, 7), (3, 7), (1, 8)):
            peer = socket.create_connection(('127.0.0.1', pp), timeout=10)
            peer.sendall(b'\x05\x01\x00'); assert receive_exact(peer, 2) == b'\x05\x00'
            peer.sendall(bytes([5, command, 0, 9 if command == 1 else 1]))
            check(receive_exact(peer, 10)[1] == reply, 'socks-reject-command-or-address-' + str(command))
            peer.close()
        peer = socket.create_connection(('127.0.0.1', pp), timeout=10)
        peer.sendall(b'\x05\x01\x02'); check(receive_exact(peer, 2) == b'\x05\xff', 'socks-reject-authentication-method'); peer.close()
        for request, expected in ((b'\x05\x01\x01\x01', 1), (b'\x05\x01\x00\x03\x00', 8),
                                  (b'\x05\x01\x00\x01\x7f\x00\x00\x01\x00\x00', 8)):
            peer = socket.create_connection(('127.0.0.1', pp), timeout=10)
            peer.sendall(b'\x05\x01\x00'); assert receive_exact(peer, 2) == b'\x05\x00'
            peer.sendall(request); check(receive_exact(peer, 10)[1] == expected, 'socks-reject-reserved-name-or-port'); peer.close()
        peer = socks_connect(pp, target.port)
        peer.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        writer = threading.Thread(target=lambda: peer.sendall(data * 4), daemon=True); writer.start()
        time.sleep(.2)
        after = len(client.events); client.send(dict(op='terminal'))
        if mode != 'forward-only': client.wait(lambda e: e.get('event') == 'terminal', after=after, timeout=3)
        received = bytearray()
        while len(received) < len(data) * 4: received.extend(peer.recv(32768))
        writer.join(timeout=15)
        check(received == data * 4 and not writer.is_alive(), 'slow-consumer-backpressure-and-terminal-fairness')
        peer.shutdown(socket.SHUT_WR); check(receive_exact(peer, 4) == b'TAIL', 'backpressure-buffered-tail'); peer.close()
        early = Peer(early_eof=True); peers.append(early)
        after = len(client.events)
        early_rule = rule('local', early.port)
        v6_local = rule('local', ipv6.port, bind='::1'); v6_local['host'] = '::1'
        v6_remote = rule('remote', ipv6.port, bind='::1'); v6_remote['host'] = '::1'
        early_client = Client([early_rule, v6_local, v6_remote]); clients.append(early_client)
        exchange(early_client.listener(v6_local), data, family=socket.AF_INET6)
        exchange(early_client.listener(v6_remote), data, family=socket.AF_INET6)
        check(True, 'ipv6-local-and-remote-listeners-and-destinations')
        port = early_client.listener(early_rule)
        peer = socket.create_connection(('127.0.0.1', port), timeout=10)
        check(receive_exact(peer, len(b'EARLY-EOF')) == b'EARLY-EOF' and peer.recv(1) == b'', 'remote-eof-does-not-close-write-direction')
        peer.sendall(data); peer.shutdown(socket.SHUT_WR)
        check(early.received.get(timeout=15) == data, 'write-after-remote-eof-byte-equality'); peer.close()
        early_client.close(); clients.remove(early_client)
        client.stop(local)
        exchange(rp, b'other-rule'); check(True, 'stop-one-rule-retains-other-rule')
        lp = client.start(local); exchange(lp, b'restarted'); check(True, 'restart-rule')
        held = socket.create_connection(('127.0.0.1', lp), timeout=10)
        held.sendall(b'active'); assert receive_exact(held, 6) == b'active'
        client.stop(local)
        try: closed = held.recv(1) == b''
        except ConnectionResetError: closed = True
        check(closed, 'stop-closes-existing-flow'); held.close()
        lp = client.start(local)
        active_port = client.start(disabled); exchange(active_port, b'disabled-start'); check(True, 'manual-start-disabled-rule')
        client.stop(remote)
        try:
            socket.create_connection(('127.0.0.1', rp), timeout=1).close(); unavailable = False
        except OSError:
            unavailable = True
        check(unavailable, 'remote-listener-cancellation')
        rp = client.start(remote); exchange(rp, b'remote-restart'); check(True, 'remote-listener-restart')
        if mode == 'forward-only':
            check(any(e.get('event') == 'terminalAvailable' and not e['value'] for e in client.events) and any(e.get('event') == 'filesAvailable' and not e['value'] for e in client.events), 'forwarding-only-authenticated-session')
        else:
            after = len(client.events); client.send(dict(op='terminal'))
            client.wait(lambda e: e.get('event') == 'terminal', after=after)
            check(True, 'terminal-remains-usable')
            # Existing SFTP and tunnels share exactly this native SSH login.
            payload = os.urandom(2 * 1024 * 1024)
            (root / 'forward-upload.bin').unlink(missing_ok=True)
            (root / 'forward-downloaded.bin').unlink(missing_ok=True)
            (root / 'forward-source.bin').write_bytes(payload)
            file_id = str(uuid.uuid4()); after = len(client.events)
            client.send(dict(op='file', id=file_id, local='forward-source.bin', remote='forward-upload.bin', upload=True))
            exchange(lp, data)
            client.wait(lambda e: e.get('event') == 'file' and e.get('id') == file_id and e['ok'], after=after)
            download = str(uuid.uuid4()); after = len(client.events)
            client.send(dict(op='file', id=download, local='forward-downloaded.bin', remote='forward-upload.bin', upload=False))
            exchange(rp, data)
            client.wait(lambda e: e.get('event') == 'file' and e.get('id') == download and e['ok'], after=after)
            check((root / 'forward-downloaded.bin').read_bytes() == payload, 'sftp-and-tunnel-concurrent-byte-equality')
            after = len(client.events); client.send(dict(op='file', id='conflict-job', local='forward-source.bin', remote='forward-upload.bin', upload=True))
            conflict = client.wait(lambda e: e.get('event') == 'conflict', after=after)
            exchange(lp, b'while-conflict-waits'); check(True, 'forwarding-during-overwrite-prompt')
            client.send(dict(op='cancelFiles'))
            client.wait(lambda e: e.get('event') == 'file' and e.get('id') == 'conflict-job', after=after)
            exchange(lp, b'after-file-cancellation'); check(True, 'file-cancellation-retains-forwarding')
        # Runtime edits drain the old rule while retaining other channels and the login.
        runtime_rule = rule('local', target.port)
        after = len(client.events)
        client.send(dict(op='update', rule=runtime_rule, start=True))
        runtime_port = client.wait(lambda e: e.get('id') == runtime_rule['id'] and e.get('state') == 'listening', after=after)['port']
        exchange(runtime_port, b'live-add')
        held = socket.create_connection(('127.0.0.1', runtime_port), timeout=10)
        held.sendall(b'held-flow'); assert receive_exact(held, 9) == b'held-flow'
        runtime_rule['kind'] = 'remote'
        after = len(client.events)
        client.send(dict(op='update', rule=runtime_rule, start=True))
        runtime_port = client.wait(lambda e: e.get('id') == runtime_rule['id'] and e.get('state') == 'listening', after=after)['port']
        try: closed = held.recv(1) == b''
        except ConnectionResetError: closed = True
        held.close(); check(closed, 'runtime-edit-closes-old-flows')
        exchange(runtime_port, b'live-replacement-remote')
        exchange(lp, b'other-rule-survives-edit')
        runtime_rule['kind'] = 'socks'
        after = len(client.events)
        client.send(dict(op='update', rule=runtime_rule, start=True))
        runtime_port = client.wait(lambda e: e.get('id') == runtime_rule['id'] and e.get('state') == 'listening', after=after)['port']
        exchange(runtime_port, b'live-replacement-socks', connected=socks_connect(runtime_port, target.port))
        runtime_rule['kind'] = 'remote'
        after = len(client.events)
        client.send(dict(op='update', rule=runtime_rule, start=True))
        client.send(dict(op='stop', id=runtime_rule['id']))
        client.wait(lambda e: e.get('id') == runtime_rule['id'] and e.get('state') == 'stopped', after=after)
        runtime_port = client.start(runtime_rule)
        exchange(runtime_port, b'replacement-stop-restart')
        check(True, 'stop-during-replacement-retains-stopped-new-configuration')
        after = len(client.events)
        client.send(dict(op='remove', id=runtime_rule['id']))
        client.wait(lambda e: e.get('id') == runtime_rule['id'] and e.get('state') == 'removed', after=after)
        try: socket.create_connection(('127.0.0.1', runtime_port), timeout=1).close(); removed = False
        except OSError: removed = True
        check(removed, 'runtime-add-edit-remote-to-socks-remove-without-reconnect')
        if mode != 'forward-only':
            empty_client = Client([]); clients.append(empty_client)
            for kind in ('local', 'remote', 'socks'):
                new_rule = rule(kind, target.port)
                after = len(empty_client.events)
                empty_client.send(dict(op='update', rule=new_rule, start=True))
                new_port = empty_client.wait(lambda e: e.get('id') == new_rule['id'] and e.get('state') == 'listening', after=after)['port']
                exchange(new_port, b'first-runtime-rule', connected=socks_connect(new_port, target.port) if kind == 'socks' else None)
                after = len(empty_client.events)
                empty_client.send(dict(op='remove', id=new_rule['id']))
                empty_client.wait(lambda e: e.get('id') == new_rule['id'] and e.get('state') == 'removed', after=after)
            empty_client.close(); clients.remove(empty_client)
            check(True, 'runtime-first-tunnel-after-empty-and-removal-for-all-types')
        client.close(); clients.remove(client)
        for port in (lp, pp, active_port):
            try: socket.create_connection(('127.0.0.1', port), timeout=1).close(); stopped = False
            except OSError: stopped = True
            check(stopped, 'disconnect-releases-listener')
        check(True, 'native-worker-drained')
    occupied.close()
finally:
    for client in clients:
        try: client.close()
        except Exception:
            client.process.kill(); client.process.wait()
    for peer in peers: peer.close()
