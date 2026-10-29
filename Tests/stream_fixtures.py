#!/usr/bin/env python3
"""Local live-radio fixtures for the smoke tests: a 440 Hz + 2 kHz tone served as
/aac        raw ADTS AAC (with ICY metadata at /aac-icy)
/vorbis     Ogg Vorbis, chained (only when ffmpeg is installed)
/opus       Ogg Opus (built from afconvert's CAF Opus packets)
/hls/*.m3u8 live HLS: MPEG-TS, packed ADTS, AES-128 encrypted TS, a master playlist, and fMP4 (unsupported)
Needs macOS (afconvert) and /usr/bin/openssl. Usage: stream_fixtures.py PORT
"""
import http.server, os, shutil, struct, subprocess, sys, tempfile, time, math, wave, zlib

SEG = 2.0                      # HLS segment seconds
work = tempfile.mkdtemp(prefix="radiopocket-fixtures-")

def tone_wav(path, seconds=8, rate=44100):
    w = wave.open(path, "wb"); w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate)
    frames = bytearray()
    for n in range(rate * seconds):
        l = int(9000 * math.sin(2 * math.pi * 440 * n / rate) + 5000 * math.sin(2 * math.pi * 2000 * n / rate))
        r = int(9000 * math.sin(2 * math.pi * 440 * n / rate))
        frames += struct.pack("<hh", l, r)
    w.writeframes(bytes(frames)); w.close()

wav = os.path.join(work, "tone.wav"); tone_wav(wav)

# ---- ADTS frames -------------------------------------------------------------------------------
aac_path = os.path.join(work, "tone.aac")
subprocess.run(["afconvert", wav, aac_path, "-f", "adts", "-d", "aac", "-b", "96000"], check=True)
raw = open(aac_path, "rb").read()
frames, i = [], 0
while i + 7 < len(raw):
    assert raw[i] == 0xFF and raw[i + 1] & 0xF0 == 0xF0, "lost ADTS sync"
    n = ((raw[i + 3] & 3) << 11) | (raw[i + 4] << 3) | (raw[i + 5] >> 5)
    frames.append(raw[i:i + n]); i += n
FRAME_SECONDS = 1024 / 44100
PER_SEG = round(SEG / FRAME_SECONDS)

def segment_frames(n):
    return b"".join(frames[(n * PER_SEG + k) % len(frames)] for k in range(PER_SEG))

# ---- MPEG-TS ------------------------------------------------------------------------------------
def crc32_mpeg(data):
    crc = 0xFFFFFFFF
    for b in data:
        crc ^= b << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
    return crc

def ts_packets(pid, payload, counter, start):
    out = []
    first = True
    while payload or first:
        header = bytearray([0x47, (0x40 if first else 0) | (pid >> 8), pid & 0xFF, 0])
        room = 184
        chunk = payload[:room]
        adaptation = b""
        if len(chunk) < room:
            pad = room - len(chunk)
            adaptation = bytes([pad - 1]) + (b"\x00" + b"\xFF" * (pad - 2) if pad >= 2 else b"")
        header[3] = (0x30 if adaptation else 0x10) | (counter[pid] & 0x0F); counter[pid] += 1
        out.append(bytes(header) + adaptation + chunk)
        payload = payload[len(chunk):]; first = False
    return out

def section(table_id, body):
    length = len(body) + 4
    head = bytes([table_id, 0xB0 | (length >> 8), length & 0xFF])
    data = head + body
    return data + struct.pack(">I", crc32_mpeg(data))

def ts_segment(n):
    counter = {0: 0, 0x1000: 0, 0x100: 0}
    pat = section(0, b"\x00\x01\xC1\x00\x00" + struct.pack(">HH", 1, 0xE000 | 0x1000))
    pmt_body = struct.pack(">H", 1) + b"\xC1\x00\x00" + struct.pack(">H", 0xE000 | 0x100) + struct.pack(">H", 0xF000) + bytes([0x0F]) + struct.pack(">HH", 0xE000 | 0x100, 0xF000)
    pmt = section(2, pmt_body)
    out = ts_packets(0, b"\x00" + pat, counter, True) + ts_packets(0x1000, b"\x00" + pmt, counter, True)
    pts = int(n * SEG * 90000)
    per_pes = 6
    group = [frames[(n * PER_SEG + k) % len(frames)] for k in range(PER_SEG)]
    for g in range(0, len(group), per_pes):
        es = b"".join(group[g:g + per_pes])
        stamp = pts + int(g * FRAME_SECONDS * 90000)
        p = bytes([0x21 | ((stamp >> 29) & 0x0E), (stamp >> 22) & 0xFF, 0x01 | ((stamp >> 14) & 0xFE), (stamp >> 7) & 0xFF, 0x01 | ((stamp << 1) & 0xFE)])
        pes = b"\x00\x00\x01\xC0" + struct.pack(">H", min(0xFFFF, len(es) + 8)) + b"\x80\x80\x05" + p + es
        out += ts_packets(0x100, pes, counter, True)
    return b"".join(out)

def id3_packed(n):
    text = b"\x03" + f"Fixture Artist - Segment {n}".encode()
    frame = b"TIT2" + struct.pack(">I", len(text)) + b"\x00\x00" + text
    size = len(frame)
    syncsafe = bytes([(size >> 21) & 0x7F, (size >> 14) & 0x7F, (size >> 7) & 0x7F, size & 0x7F])
    return b"ID3\x04\x00\x00" + syncsafe + frame

KEY = bytes(range(16)); IV = bytes(range(16, 32))
def encrypt(data):
    pad = 16 - len(data) % 16
    data += bytes([pad]) * pad
    return subprocess.run(["/usr/bin/openssl", "enc", "-aes-128-cbc", "-K", KEY.hex(), "-iv", IV.hex(), "-nopad"], input=data, capture_output=True, check=True).stdout

# ---- Ogg Opus -----------------------------------------------------------------------------------
def ogg_crc(data):
    crc = 0
    for b in data:
        crc ^= b << 24
        for _ in range(8):
            crc = ((crc << 1) ^ 0x04C11DB7) & 0xFFFFFFFF if crc & 0x80000000 else (crc << 1) & 0xFFFFFFFF
    return crc

def ogg_page(serial, seq, flags, granule, packets):
    lacing = bytearray()
    for p in packets:
        n = len(p)
        while n >= 255: lacing.append(255); n -= 255
        lacing.append(n)
    header = b"OggS" + bytes([0, flags]) + struct.pack("<qIII", granule, serial, seq, 0) + bytes([len(lacing)]) + bytes(lacing)
    page = header + b"".join(packets)
    return page[:22] + struct.pack("<I", ogg_crc(page)) + page[26:]

def caf_opus_packets(path):
    d = open(path, "rb").read(); at = 8; packets_sizes = []; data = b""; frames_per_packet = 960
    while at + 12 <= len(d):
        kind = d[at:at + 4]; size = struct.unpack(">q", d[at + 4:at + 12])[0]; body = d[at + 12:at + 12 + size]
        if kind == b"desc": frames_per_packet = struct.unpack(">I", body[20:24])[0] or 960
        if kind == b"pakt":
            count = struct.unpack(">q", body[:8])[0]; p = 24
            for _ in range(count):
                v = 0
                while True:
                    b = body[p]; p += 1; v = (v << 7) | (b & 0x7F)
                    if not b & 0x80: break
                packets_sizes.append(v)
        if kind == b"data": data = body[4:]
        at += 12 + size
    out, o = [], 0
    for s in packets_sizes: out.append(data[o:o + s]); o += s
    return out, frames_per_packet

caf = os.path.join(work, "tone.caf")
subprocess.run(["afconvert", wav, caf, "-f", "caff", "-d", "opus@48000", "-b", "64000"], check=True)
opus_packets, opus_frames = caf_opus_packets(caf)
def opus_headers():
    head = b"OpusHead" + bytes([1, 2]) + struct.pack("<HIhB", 312, 44100, 0, 0)
    vendor = b"RadioPocket fixture"; comments = [b"TITLE=Opus Fixture Tone", b"ARTIST=RadioPocket"]
    tags = b"OpusTags" + struct.pack("<I", len(vendor)) + vendor + struct.pack("<I", len(comments)) + b"".join(struct.pack("<I", len(c)) + c for c in comments)
    return ogg_page(7, 0, 2, 0, [head]) + ogg_page(7, 1, 0, 0, [tags])

# ---- Ogg Vorbis (needs ffmpeg; macOS has no Vorbis encoder) --------------------------------------
vorbis_pages = []
ffmpeg = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"
if os.path.exists(ffmpeg):
    ogg_path = os.path.join(work, "tone.ogg")
    subprocess.run([ffmpeg, "-loglevel", "error", "-y", "-i", wav, "-c:a", "vorbis", "-strict", "-2", "-q:a", "4",
                    "-metadata", "title=Vorbis Fixture Tone", "-metadata", "artist=RadioPocket", ogg_path], check=True)
    blob = open(ogg_path, "rb").read(); at = 0; last = 0
    while at + 27 <= len(blob) and blob[at:at + 4] == b"OggS":
        n = blob[at + 26]; size = 27 + n + sum(blob[at + 27:at + 27 + n])
        granule = struct.unpack("<q", blob[at + 6:at + 14])[0]
        delay = max(0, granule - last) / 44100 if granule > 0 else 0
        if granule > 0: last = granule
        vorbis_pages.append((blob[at:at + size], delay)); at += size

# ---- HTTP ---------------------------------------------------------------------------------------
start = time.time()
connections = {}
def paced_aac(limit=None):
    """Real-time ADTS: ten frames at a time, roughly as fast as they play."""
    sent = 0.0
    while limit is None or sent < limit:
        for i in range(0, len(frames), 10):
            yield b"".join(frames[i:i + 10]), 10 * FRAME_SECONDS * 0.97
            sent += 10 * FRAME_SECONDS
            if limit is not None and sent >= limit: return

class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *a): pass
    def send(self, body, kind):
        self.send_response(200); self.send_header("Content-Type", kind); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def stream(self, kind, chunks, headers=()):
        self.send_response(200); self.send_header("Content-Type", kind)
        for k, v in headers: self.send_header(k, v)
        self.end_headers()
        try:
            for chunk, delay in chunks: self.wfile.write(chunk); self.wfile.flush(); time.sleep(delay)
        except Exception: pass
    def sequence(self): return int((time.time() - start) / SEG) + 3
    def playlist(self, extra, name, ext, key=False):
        top = self.sequence(); first = top - 3
        lines = ["#EXTM3U", "#EXT-X-VERSION:3", f"#EXT-X-TARGETDURATION:{int(math.ceil(SEG))}", f"#EXT-X-MEDIA-SEQUENCE:{first}"] + extra
        if key: lines.append(f'#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x{IV.hex()}')
        for n in range(first, top + 1): lines += [f"#EXTINF:{SEG:.3f},", f"{name}{n}.{ext}"]
        self.send(("\n".join(lines) + "\n").encode(), "application/vnd.apple.mpegurl")
    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/aac", "/aac-icy"):
            icy = path == "/aac-icy"
            blob = b"".join(frames)
            def gen():
                n = 0
                while True:
                    for i in range(0, len(blob), 2400):
                        piece = blob[i:i + 2400]
                        if icy:
                            piece = piece[:2000].ljust(2000, b"\x00")[:2000]
                        yield piece, 0.16
            if not icy:
                return self.stream("audio/aac", gen())
            # ICY: metadata block after every 8000 audio bytes
            def icy_gen():
                buf = b""
                count = 0
                while True:
                    for fr in frames:
                        buf += fr
                        while len(buf) >= 8000:
                            meta = f"StreamTitle='ICY Fixture {count}';".encode(); count += 1
                            padded = meta + b"\x00" * (-len(meta) % 16)
                            yield buf[:8000] + bytes([len(padded) // 16]) + padded, 0.65
                            buf = buf[8000:]
            return self.stream("audio/aac", icy_gen(), [("icy-metaint", "8000")])
        if path in ("/aac-flaky", "/aac-stall"):
            # The first connection misbehaves (drops after 3 s, or goes silent without closing); later ones are healthy.
            connections[path] = connections.get(path, 0) + 1
            if connections[path] == 1:
                def gen():
                    yield from paced_aac(3)
                    if path == "/aac-stall": time.sleep(60)
                return self.stream("audio/aac", gen())
            return self.stream("audio/aac", paced_aac())
        if path == "/vorbis" and vorbis_pages:
            def gen():
                while True:                     # every repetition starts a new chained logical stream
                    for page, delay in vorbis_pages: yield page, delay * 0.98
            return self.stream("audio/ogg", gen())
        if path == "/opus":
            def gen():
                yield opus_headers(), 0
                seq, granule, i = 2, 0, 0
                while True:
                    group = [opus_packets[(i + k) % len(opus_packets)] for k in range(10)]; i += 10
                    granule += opus_frames * 10
                    yield ogg_page(7, seq, 0, granule, group), 0.2 * 0.98; seq += 1
            return self.stream("audio/ogg", gen())
        if path == "/hls/live.m3u8": return self.playlist([], "ts", "ts")
        if path == "/hls/live-packed.m3u8": return self.playlist([], "pk", "aac")
        if path == "/hls/live-aes.m3u8": return self.playlist([], "enc", "ts", key=True)
        if path == "/hls/live-fmp4.m3u8": return self.playlist(['#EXT-X-MAP:URI="init.mp4"'], "ts", "ts")
        if path == "/hls/master.m3u8":
            return self.send(b'#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1200000,CODECS="avc1.4d401f,mp4a.40.2"\nvideo.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS="mp4a.40.5"\nlive.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=128000,CODECS="mp4a.40.2"\nlive-packed.m3u8\n', "application/vnd.apple.mpegurl")
        if path == "/hls/key.bin": return self.send(KEY, "application/octet-stream")
        if path.startswith("/hls/ts") and path.endswith(".ts"): return self.send(ts_segment(int(path[7:-3])), "video/mp2t")
        if path.startswith("/hls/enc") and path.endswith(".ts"): return self.send(encrypt(ts_segment(int(path[8:-3]))), "video/mp2t")
        if path.startswith("/hls/pk") and path.endswith(".aac"): n = int(path[7:-4]); return self.send(id3_packed(n) + segment_frames(n), "audio/aac")
        self.send_response(404); self.end_headers()

if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler)
    print("fixtures on", sys.argv[1], flush=True)
    server.serve_forever()
