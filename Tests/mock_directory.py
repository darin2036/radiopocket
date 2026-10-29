"""Local-only directory fixture. Optional RADIOPOCKET_TEST_AUDIO points to an MP3.
Run with: python3 Tests/mock_directory.py
"""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs
from pathlib import Path
import json, os, time, uuid

PORT = int(os.environ.get('RADIOPOCKET_TEST_PORT', '18765'))
COUNTS = {}
class Handler(BaseHTTPRequestHandler):
    def send(self, code, data, kind='application/json'):
        self.send_response(code)
        self.send_header('Content-Type', kind)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass
    def do_GET(self):
        parsed = urlsplit(self.path)
        args = parse_qs(parsed.query)
        name = args.get('name', [''])[0]
        if parsed.path == '/live':
            audio = os.environ.get('RADIOPOCKET_TEST_AUDIO')
            if not audio: self.send(404, b'{}'); return
            data = Path(audio).read_bytes()
            self.send_response(200); self.send_header('Content-Type', 'audio/mpeg'); self.end_headers()
            try:
                while True:
                    for offset in range(0, len(data), 2048):
                        self.wfile.write(data[offset:offset+2048]); self.wfile.flush(); time.sleep(.12)
            except (BrokenPipeError, ConnectionResetError): pass
            return
        if parsed.path == '/counts': self.send(200, json.dumps(COUNTS).encode()); return
        COUNTS[self.path] = COUNTS.get(self.path, 0) + 1
        if parsed.path.startswith('/json/url/'):
            self.send(200, b'{"ok":"true"}'); return
        if parsed.path.startswith('/json/stations/byuuid/'):
            ident = parsed.path.rsplit('/', 1)[1]
            if ident == str(uuid.UUID(int=77)):
                self.send(200, json.dumps([{'stationuuid': ident, 'name': 'Moved Radio', 'url': f'http://127.0.0.1:{PORT}/live?moved=1',
                    'url_resolved': f'http://127.0.0.1:{PORT}/live?moved=1', 'codec': 'MP3', 'bitrate': 128, 'votes': 5, 'clickcount': 5, 'hls': 0}]).encode())
            else: self.send(200, b'[]')
            return
        if parsed.path != '/json/stations/search': self.send(404, b'{}'); return
        if name == 'failure': self.send(503, b'{}'); return
        if name == 'badjson': self.send(200, b'invalid JSON'); return
        if name == 'oversize': self.send(200, b' ' * 2_100_000); return
        if name == 'slow': time.sleep(6)
        if name == 'empty': self.send(200, b'[]'); return
        offset = int(args.get('offset', ['0'])[0])
        count = 100 if offset == 0 else 3
        rows = []
        for i in range(offset, offset + count):
            rows.append({'stationuuid': str(uuid.UUID(int=i+1)),
                'name': (name or 'Test') + f' Radio {i+1:03d}',
                'url': f'http://127.0.0.1:{PORT}/live?station={i}',
                'url_resolved': f'http://127.0.0.1:{PORT}/live?station={i}',
                'tags': args.get('tag', ['jazz,independent'])[0],
                'countrycode': args.get('countrycode', ['US'])[0],
                'codec': args.get('codec', ['MP3'])[0], 'bitrate': 128,
                'votes': 100-i, 'clickcount': 1000-i, 'hls': 0})
        self.send(200, json.dumps(rows).encode())

ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
