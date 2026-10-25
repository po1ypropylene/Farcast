#!/usr/bin/env python3
"""Independent synthetic Apple RSA-SRP/record-layer peer; no real account data."""
import ctypes
import hashlib
import hmac
import os
import pathlib
import socket
import struct
import sys
import zlib
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

root, scenario = pathlib.Path(sys.argv[1]), sys.argv[2]
lib = ctypes.CDLL(str(pathlib.Path('Vendor/Native/lib/libcrypto.3.dylib').resolve()))
class Group(ctypes.Structure):
    _fields_ = [('name', ctypes.c_char_p), ('g', ctypes.c_void_p), ('N', ctypes.c_void_p)]
lib.SRP_get_default_gN.argtypes = [ctypes.c_char_p]
lib.SRP_get_default_gN.restype = ctypes.POINTER(Group)
lib.BN_bn2binpad.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]
buf = ctypes.create_string_buffer(512)
lib.BN_bn2binpad(lib.SRP_get_default_gN(b'4096').contents.N, buf, 512)
N, g = int.from_bytes(buf.raw, 'big'), 5
H = lambda *parts: hashlib.sha512(b''.join(parts)).digest()
pad = lambda x: x.to_bytes(512, 'big')
u16 = lambda n: struct.pack('>H', n)
u32 = lambda n: struct.pack('>I', n)
atom = lambda d: u16(len(d)) + d
small = lambda d: bytes([len(d)]) + d

def exact(s, n):
    data = b''
    while len(data) < n:
        part = s.recv(n - len(data))
        if not part: raise EOFError()
        data += part
    return data

def envelope(s):
    n = struct.unpack('>I', exact(s, 4))[0]
    assert 10 <= n <= 8192
    d = exact(s, n)
    assert d[:6] == b'\x01\x00RSA1'
    kind, size = struct.unpack('>HH', d[6:10])
    assert size <= len(d) - 10
    return kind, d[10:10+size]

def frame(payload):
    return u32(len(payload)+10) + u16(0) + u16(2) + u16(len(payload)+4) + u32(len(payload)) + payload

class Records:
    def __init__(self, s, key, iv):
        self.s = s
        self.enc = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
        self.dec = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
        self.tx = self.rx = 0
    def read(self):
        n = struct.unpack('>H', exact(self.s, 2))[0]
        assert n and n % 16 == 0
        p = self.dec.update(exact(self.s, n))
        assert hmac.compare_digest(p[-20:], hashlib.sha1(u32(self.rx)+p[:-20]).digest())
        self.rx += 1
        size = struct.unpack('>H', p[:2])[0]
        assert 0 < size <= n-22
        return p[2:2+size]
    def send(self, d, bad=False):
        for offset in range(0, len(d), 4096):
            part = d[offset:offset+4096]
            out = self.encode(part,bad)
            self.s.sendall(out[:1]); self.s.sendall(out[1:7]); self.s.sendall(out[7:])
    def encode(self, part, bad=False):
        prefix = u16(len(part))+part
        prefix += b'\xa5' * ((-len(prefix)-20) % 16)
        tag = hashlib.sha1(u32(self.tx)+prefix).digest()
        if bad: tag = bytes([tag[0]^1])+tag[1:]
        wire = self.enc.update(prefix+tag)
        self.tx += 1
        return u16(len(wire))+wire

def run(s):
    s.settimeout(15)
    s.sendall(b'RFB 003.889\n')
    assert exact(s, 12) == b'RFB 003.889\n'
    s.sendall(b'\x02\x02\x21')
    assert exact(s, 1) == b'\x21'  # No classic-password downgrade.
    kind, payload = envelope(s)
    assert kind == 0 and not payload
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    der = key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    (root/'public.der').write_bytes(der)
    s.sendall(u32(len(der)+7)+struct.pack('<I',0x100)+u16(len(der))+der+b'\0')
    if scenario == 'trust-refusal':
        assert s.recv(1) == b''
        return
    kind, identity = envelope(s)
    plain = key.decrypt(identity, padding.PKCS1v15())
    assert struct.unpack('>I',plain[:4])[0] == len(plain)-4
    assert plain[8:-3] == b'fixture'
    salt, iterations = os.urandom(32), 1137
    derived = hashlib.pbkdf2_hmac('sha512', b'fixture-password', salt, iterations, 128)
    x = int.from_bytes(H(salt,H(b':',derived)), 'big')
    v = pow(g,x,N)
    k = int.from_bytes(H(pad(N),pad(g)), 'big')
    b = int.from_bytes(os.urandom(32),'big')
    B = (k*v+pow(g,b,N)) % N
    options=b'mda=SHA-512,replay_detection,conf+int=ChaCha20-Poly1305,kdf=SALTED-SHA512-PBKDF2'
    challenge = b'\0'+atom(pad(N))+atom(bytes([g]))+small(salt)+atom(pad(B))+struct.pack('>Q',iterations)+atom(options)
    if scenario == 'bad-group':
        challenge = b'\0'+atom(bytes(512))+atom(bytes([g]))+small(salt)+atom(pad(B))+struct.pack('>Q',iterations)+atom(options)
    s.sendall(frame(challenge))
    if scenario == 'bad-group':
        assert s.recv(1) == b''
        return
    kind, body = envelope(s)
    assert kind == 2 and body[:2] == b'\0\0'
    size = struct.unpack('>H',body[2:4])[0]
    p = body[4:4+size]
    n = struct.unpack('>H',p[:2])[0]
    A = int.from_bytes(p[2:2+n],'big')
    pos=2+n; m1len=p[pos]; M1=p[pos+1:pos+1+m1len]
    u = int.from_bytes(H(pad(A),pad(B)), 'big')
    S = pow((A*pow(v,u,N))%N,b,N)
    K = H(pad(S))
    expected = H(bytes(a^b for a,b in zip(H(pad(N)),H(pad(g)))),H(b''),salt,pad(A),pad(B),K)
    assert hmac.compare_digest(expected,M1), 'Client SRP proof mismatch'
    M2=H(pad(A),M1,K)
    if scenario == 'bad-proof': M2=bytes(64)
    s.sendall(frame(small(M2)+small(os.urandom(16))+atom(b'')+u32(0)))
    if scenario == 'bad-proof':
        assert s.recv(1) == b''
        return
    s.sendall(u32(0))
    assert exact(s,1) == b'\xc1'
    name = b''
    if scenario.startswith('desktop-login'):
        selection = u16(74)+u16(1)+u32(0 if scenario=='desktop-login-capabilities' else 4)+u32(0)+bytes(64)
        name = u16(0)+u32(4)+bytes(16)+selection
    s.sendall(struct.pack('>HH',640,480)+bytes([32,24,0,1])+struct.pack('>HHH',255,255,255)+bytes([16,8,0,0,0,0])+u32(len(name))+name)
    if scenario.startswith('desktop-login'):
        if scenario=='desktop-login-capabilities':
            assert s.recv(1)==b''
            return
        login=exact(s,202)
        assert login[:10]==u16(200)+u16(2)+u32(0)+bytes([2,0])
        assert login[10:18]==b'Farcast\0'
        wrap=hashlib.sha256(K).digest()[:16]
        decoder=Cipher(algorithms.AES(wrap),modes.ECB()).decryptor()
        credentials=decoder.update(login[74:202])
        assert credentials[:64].split(b'\0')[0]==b'fixture'
        assert credentials[64:].split(b'\0')[0]==b'fixture-password'
        # Account bytes must be inside the encrypted credential fields only.
        assert b'fixture' not in login and b'fixture-password' not in login
        status=3 if scenario=='desktop-login-denied' else 2
        reply=u16(0 if scenario=='desktop-login-version' else 1)+bytes([status])+bytes(77)
        wire=u16(len(reply))+reply
        s.sendall(wire[:1]);s.sendall(wire[1:5]);s.sendall(wire[5:])
        if scenario in ('desktop-login-denied','desktop-login-version'):
            assert s.recv(1)==b''
            return
    viewer = exact(s,66)
    assert viewer[:6] == bytes.fromhex('2100003e0001')
    assert viewer[36] & 8  # Supports framed server status commands.
    assert exact(s,12)==bytes.fromhex('120000010001000100000001')
    wrap=hashlib.sha256(K).digest()[:16]
    newkey,iv=os.urandom(16),os.urandom(16)
    ecb=Cipher(algorithms.AES(wrap),modes.ECB()).encryptor()
    rekey=u32(1)+ecb.update(newkey+iv)
    s.sendall(b'\0\0\0\1'+struct.pack('>HHHHi',0,0,0,0,0x44f)+rekey)
    assert exact(s,8)==bytes.fromhex('1200000200010000')
    records=Records(s,newkey,iv)
    configuration=records.read()
    assert configuration[0]==0x1d and len(configuration)==196
    assert struct.unpack('>H',configuration[2:4])[0]==192
    assert struct.unpack('>HHHH',configuration[4:12])[:2]==(1,1)
    encoding_offer=records.read()
    assert encoding_offer[0]==2
    if scenario in ('adaptive-refusal','adaptive-answer-refusal'):
        assert len(encoding_offer)==52 and encoding_offer[4:8]==u32(0x3f2)
    else:
        assert len(encoding_offer)==48
    assert records.read()[0]==0
    assert records.read()==bytes.fromhex('0a000001')
    assert records.read()[0]==9
    assert records.read()[0]==3
    if scenario in ('adaptive-refusal','adaptive-answer-refusal'):
        request=bytearray(38)
        struct.pack_into('>HHH',request,0,36,1,1)
        if scenario=='adaptive-answer-refusal':
            udp=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
            udp.bind(('127.0.0.1',0)); port=udp.getsockname()[1]; udp.close()
            struct.pack_into('>HI',request,16,port,1)
        records.send(bytes(4)[:2]+u16(1)+struct.pack('>HHHHi',0,0,0,0,0x3f2)+request)
        if scenario=='adaptive-answer-refusal':
            configuration=records.read()
            assert configuration[0:2]==bytes([0x1c,0]) and len(configuration)==struct.unpack('>H',configuration[2:4])[0]+4
            assert configuration[6:10]==bytes([5,0,0,0]), 'One stream, no embedded cursor'
            # Server refusal is a framed media message, not a top-level RFB type.
            records.send(b'\0\0\0\1'+struct.pack('>HHHHi',0,0,0,0,0x3f2)+u16(4)+u16(3)+u16(1))
            assert records.read()[0]==3
        fallback=records.read()
        assert fallback[0]==2 and len(fallback)==48 and u32(0x3f2) not in fallback[4:]
        assert records.read()==bytes.fromhex('0a000001')
        assert records.read()[0]==9 and records.read()[0]==3
        assert records.read()[0]==3
    if scenario=='rekey-input':
        nextkey,nextiv=os.urandom(16),os.urandom(16)
        encoder=Cipher(algorithms.AES(newkey),modes.ECB()).encryptor()
        records.send(b'\0\0\0\1'+struct.pack('>HHHHi',0,0,0,0,0x44f)+u32(2)+encoder.update(nextkey+nextiv))
        # Retain sequence counters while replacing both directional ciphers.
        records.enc=Cipher(algorithms.AES(nextkey),modes.CBC(nextiv)).encryptor()
        records.dec=Cipher(algorithms.AES(nextkey),modes.CBC(nextiv)).decryptor()
        newkey=nextkey
        assert records.read()[0:2]==bytes([3,1])
    def draw(w,h):
        body=bytearray(76)
        struct.pack_into('>HIIH',body,0,5,0,0x02000000,1)
        struct.pack_into('>HHHH',body,32,0,0,w,h)
        factor=2 if scenario=='retina-input' else 1
        struct.pack_into('>HHHH',body,40,0,0,w//factor,h//factor)
        layout=(struct.pack('>HHHHi',0,0,w,h,-223) if scenario == 'desktop-size' else struct.pack('>HHHHi',0,0,w,h,0x451)+u16(len(body))+body)
        records.send(b'\0\0\0\1'+layout,bad=scenario=='bad-integrity')
        if scenario=='bad-integrity': return
        assert records.read()==bytes.fromhex('0a000001')
        assert records.read()[0]==9 and records.read()[0]==3
        pixels=bytes([17,41,83,255])*(w*h)
        compressed=zlib.compress(pixels)
        records.send(b'\0\0\0\1'+struct.pack('>HHHHi',0,0,w,h,6)+u32(len(compressed))+compressed)
    factor=2 if scenario=='retina-input' else 1
    draw(640*factor,480*factor)
    if scenario=='bad-integrity':
        assert s.recv(1)==b''
        return
    refresh=records.read()
    assert refresh[0:2]==bytes([3,1]), 'Missing incremental request after first pixels'
    assert struct.unpack('>HH',refresh[6:10])==(640*factor,480*factor)
    resize=records.read()
    assert resize[0]==0x1d
    assert struct.unpack('>IIII',resize[168:184])==(800*factor,600*factor,800,600)
    def input_event(flags, expected):
        packet=records.read()
        assert len(packet)==18 and packet[:2]==bytes([0x10,flags])
        # Native input ECB and outer CBC both adopt the current session key.
        decoder=Cipher(algorithms.AES(newkey),modes.ECB()).decryptor()
        assert decoder.update(packet[2:])==expected
    input_event(0, bytes.fromhex('ff010000ff0900000000000000000000'))
    input_event(0, bytes.fromhex('ff000000ff0900000000000000000000'))
    for mask in (1,0):
        input_event(1, bytes(10)+bytes([0xff,mask])+u16(640*factor-1)+u16(480*factor-1))
    for down,keys in ((1,(0xffe3,0xffe9,0xffff)),(0,(0xffff,0xffe9,0xffe3))):
        for key in keys:
            input_event(0, bytes([0xff,down])+u32(key)+bytes(10))
    for key in (0x41,0x0101f600):
        for down in (1,0):
            input_event(0, bytes([0xff,down])+u32(key)+bytes(10))
    # The peer stays silent until a refresh request, then changes a pixel in
    # response to input without a resize or a fresh connection.
    redraw=b'\0\0\0\1'+struct.pack('>HHHHi',0,0,1,1,0)+bytes([29,41,83,255])
    if scenario=='input-latency':
        wire=records.encode(redraw)
        s.sendall(wire[:10])
        s.settimeout(2)
        for down in (1,0):
            input_event(0, bytes([0xff,down])+u32(0xff1b)+bytes(10))
        s.settimeout(15)
        s.sendall(wire[10:])
    else:
        records.send(redraw)
    assert records.read()[0:2]==bytes([3,1]), 'Refresh loop stopped after interactive redraw'
    draw(800*factor,600*factor)
    try:
        while s.recv(4096): pass
    except ConnectionResetError: pass

listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen(1)
(root/'port').write_text(str(listener.getsockname()[1]))
try:
    with listener.accept()[0] as s: run(s)
    (root/'result').write_text('PASS')
except Exception as e:
    (root/'result').write_text(type(e).__name__+': '+str(e))
    raise
finally:
    listener.close()
