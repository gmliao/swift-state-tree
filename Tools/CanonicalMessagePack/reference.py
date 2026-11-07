"""Reference canonical MessagePack encoder (standard library only), written from the rules in
Notes/plans/2026-11-07-streaming-record-format.md section 2, independently of the Swift encoder.

Regenerates the expected values in Tests/SwiftStateTreeTests/CanonicalMessagePackFixtures.swift:
    python3 Tools/CanonicalMessagePack/reference.py edge
    python3 Tools/CanonicalMessagePack/reference.py Examples/GameDemo/reevaluation-records/3-hero-defense.json
"""
import struct, math, json, hashlib, sys, datetime

def enc(v, out):
    if v is None: out.append(0xc0)
    elif v is True: out.append(0xc3)
    elif v is False: out.append(0xc2)
    elif isinstance(v, int):
        if v >= 0:
            if v <= 0x7f: out.append(v)
            elif v <= 0xff: out += b'\xcc' + struct.pack('>B', v)
            elif v <= 0xffff: out += b'\xcd' + struct.pack('>H', v)
            elif v <= 0xffffffff: out += b'\xce' + struct.pack('>I', v)
            else: out += b'\xcf' + struct.pack('>Q', v)
        else:
            if v >= -32: out += struct.pack('>b', v)
            elif v >= -128: out += b'\xd0' + struct.pack('>b', v)
            elif v >= -32768: out += b'\xd1' + struct.pack('>h', v)
            elif v >= -2**31: out += b'\xd2' + struct.pack('>i', v)
            else: out += b'\xd3' + struct.pack('>q', v)
    elif isinstance(v, float):
        out.append(0xcb)
        out += b'\x7f\xf8\x00\x00\x00\x00\x00\x00' if math.isnan(v) else struct.pack('>d', v)
    elif isinstance(v, str):
        b = v.encode('utf-8'); hdr(len(b), 0xa0, 31, 0xd9, 0xda, 0xdb, out); out += b
    elif isinstance(v, list):
        hdr(len(v), 0x90, 15, None, 0xdc, 0xdd, out)
        for x in v: enc(x, out)
    elif isinstance(v, dict):
        hdr(len(v), 0x80, 15, None, 0xde, 0xdf, out)
        for k in sorted(v, key=lambda k: k.encode('utf-8')):
            enc(k, out); enc(v[k], out)
    else: raise TypeError(type(v))

def hdr(n, fix, fixmax, u8, u16, u32, out):
    if n <= fixmax: out.append(fix | n)
    elif u8 is not None and n <= 0xff: out += bytes([u8]) + struct.pack('>B', n)
    elif n <= 0xffff: out += bytes([u16]) + struct.pack('>H', n)
    else: out += bytes([u32]) + struct.pack('>I', n)

def f32(x): return struct.unpack('>f', struct.pack('>f', x))[0]
def date(s):
    secs = math.floor(s)
    return (datetime.datetime(1970,1,1) + datetime.timedelta(seconds=secs)).strftime('%Y-%m-%dT%H:%M:%SZ')

def encode(v):
    out = bytearray(); enc(v, out); return bytes(out)

if sys.argv[1] == 'edge':
    edge = {
        "ints": [0, 127, 128, -1, -32, -33, -2**63, 2**63-1],
        "uint": 2**64-1,
        "doubles": [0.1, -0.0, math.inf, -math.inf, math.nan, 1e300, 5e-324],
        "floats": [f32(0.1), 1.5, math.nan],
        "keys": {"B": 1, "a": 2, "é": 3, "\U0001F600": 4, "": 5},
        "nfd": {"é": 1},
        "dates": [date(0), date(-1.5), date(1_700_000_000.9)],
        "nested": {"z": {"y": [1]}, "a": {}},
        "empty": [],
        "emptyMap": {},
    }
    print(encode(edge).hex())
else:
    data = encode(json.load(open(sys.argv[1])))
    print(len(data), hashlib.sha256(data).hexdigest())
