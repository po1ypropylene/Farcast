"""Owned OpenVPN peer: certificate verification, shared leases, refusal and cleanup.
No OS TUN, routes or DNS are touched. The peer uses dev null.
"""
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import time

root, server_binary, helper_binary = map(Path, sys.argv[1:4])
transport = sys.argv[4] if len(sys.argv) > 4 else "udp"
server_transport = "udp" if transport == "udp" else "tcp-server"
client_transport = "udp" if transport == "udp" else "tcp-client"
processes = []

def run(*args):
    subprocess.run(args, cwd=root, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

def cert(name, purpose):
    run('openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-subj', '/CN=' + name,
        '-keyout', name + '.key', '-out', name + '.csr')
    (root / (name + '.ext')).write_text('keyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=' + purpose + '\n')
    run('openssl', 'x509', '-req', '-in', name + '.csr', '-CA', 'ca.crt', '-CAkey', 'ca.key',
        '-CAcreateserial', '-days', '1', '-extfile', name + '.ext', '-out', name + '.crt')

def receive(process, timeout=40):
    ready, _, _ = select.select([process.stdout], [], [], timeout)
    if not ready:
        raise AssertionError('OpenVPN helper response timed out')
    response = process.stdout.readline()
    if not response:
        raise AssertionError('OpenVPN helper exited without response')
    return json.loads(response)

def send(process, request):
    process.stdin.write(json.dumps(request).encode() + b'\n')
    process.stdin.flush()

try:
    run('openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=Farcast fixture CA',
        '-keyout', 'ca.key', '-out', 'ca.crt')
    cert('server', 'serverAuth')
    cert('client', 'clientAuth')
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    config = f'''local 127.0.0.1
port {port}
proto {server_transport}
dev null
tls-server
dh none
ca ca.crt
cert server.crt
key server.key
ifconfig-noexec
route-noexec
push "ifconfig 10.99.0.2 10.99.0.1"
push "route 10.99.0.0 255.255.255.0"
data-ciphers AES-256-GCM:AES-128-GCM
remote-cert-tls client
verb 6
'''
    (root / 'server.conf').write_text(config)
    log = open(root / 'server.log', 'wb')
    server = subprocess.Popen([str(server_binary), '--config', 'server.conf'], cwd=root, stdout=log, stderr=log)
    processes.append(server)
    time.sleep(0.5)
    if server.poll() is not None:
        # Only owned synthetic configuration is ever included in fixture diagnostics.
        raise AssertionError((root / 'server.log').read_text())
    profile = f'client\ndev tun\nproto {client_transport}\nremote 127.0.0.1 {port}\nremote-cert-tls server\n'
    for tag, file in [('ca', 'ca.crt'), ('cert', 'client.crt'), ('key', 'client.key')]:
        profile += f'<{tag}>\n{(root / file).read_text()}</{tag}>\n'
    helper = subprocess.Popen([str(helper_binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=open(root / "client.log", "wb"))
    processes.append(helper)
    token = os.urandom(32)
    request = {'command': 'open', 'configuration': {}, 'openVPN': {'profile': profile, 'username': '', 'password': '', 'passphrase': ''},
               'host': '192.0.2.10', 'port': 22, 'token': token.hex()}
    send(helper, request)
    reply = receive(helper)
    assert reply.get('port'), f'OpenVPN negotiation failed: {reply}\n' + (root / 'client.log').read_text() + (root / 'server.log').read_text()
    with socket.create_connection(('127.0.0.1', reply['port']), timeout=3) as session:
        session.sendall(token)
        assert session.recv(1) == b'\x04', 'Destination outside VPN routes must fail closed'
    token2 = os.urandom(32)
    request.update(token=token2.hex())
    send(helper, request)
    reply2 = receive(helper, 3)
    assert reply2.get('port'), 'Second lease must reuse the authenticated VPN'
    send(helper, {'command': 'close', 'token': token.hex()})
    with socket.create_connection(('127.0.0.1', reply2['port']), timeout=3) as session:
        session.sendall(token2)
        assert session.recv(1) == b'\x04', 'Closing one lease must preserve the other'
    # The owned null-device peer discards plaintext IP packets, but its TUN-write
    # probe proves that gVisor's SYN traversed the socketpair and encrypted data channel.
    token3 = os.urandom(32)
    request.update(token=token3.hex(), host='10.99.0.1')
    send(helper, request)
    reply3 = receive(helper, 3)
    with socket.create_connection(('127.0.0.1', reply3['port']), timeout=3) as session:
        session.sendall(token3)
        deadline = time.monotonic() + 5
        while 'FARCAST_FIXTURE_DECRYPTED_TCP_SYN' not in (root / 'server.log').read_text() and time.monotonic() < deadline:
            time.sleep(0.05)
        assert 'FARCAST_FIXTURE_DECRYPTED_TCP_SYN' in (root / 'server.log').read_text(), 'Encrypted IP data did not reach the peer\n' + (root / 'server.log').read_text()
        send(helper, {'command': 'close', 'token': token3.hex()})
    helper.stdin.close()
    helper.wait(timeout=5)
    assert helper.returncode == 0
    assert not (root / 'client.log').read_bytes(), 'Helper must not log profile or server data'
    print(f'PASS OpenVPN {transport}: verified TLS, encrypted IP delivery, shared leases, route refusal and EOF cleanup')
    server.terminate()
    server.wait(timeout=5)
    server = subprocess.Popen([str(server_binary), '--config', 'server.conf'], cwd=root, stdout=log, stderr=log)
    processes.append(server)
    time.sleep(0.2)
    rejected = subprocess.Popen([str(helper_binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    processes.append(rejected)
    request['openVPN']['profile'] = profile + 'verify-x509-name rejected-server name\n'
    send(rejected, request)
    assert receive(rejected).get('error'), 'Wrong server certificate identity must fail'
    rejected.wait(timeout=5)
    assert rejected.returncode != 0
    print(f'PASS OpenVPN {transport}: mismatched server certificate identity refused')
    cancelled = subprocess.Popen([str(helper_binary)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    processes.append(cancelled)
    request['openVPN']['profile'] = profile.replace(str(port), '1')
    send(cancelled, request)
    time.sleep(0.2)
    cancelled.terminate()
    cancelled.wait(timeout=5)
    print(f'PASS OpenVPN {transport}: cancellation during negotiation exits promptly')
finally:
    for process in reversed(processes):
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
