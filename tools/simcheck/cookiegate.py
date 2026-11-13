import http.server, socketserver, struct, zlib
from socketserver import ThreadingMixIn

def make_png(w, h):
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter type 0
        for x in range(w):
            raw += bytes((220, 40, 40))  # solid red RGB
    def chunk(typ, data):
        c = struct.pack(">I", len(data)) + typ + data
        return c + struct.pack(">I", zlib.crc32(typ + data) & 0xffffffff)
    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)
    idat = zlib.compress(bytes(raw), 9)
    return sig + chunk(b"IHDR", ihdr) + chunk(b"IDAT", idat) + chunk(b"IEND", b"")

PNG = make_png(400, 400)

PAGE = ("""<!doctype html><html lang="ja"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Cookie Gate</title></head>
<body><h1>CloudFront fu Cookie gate</h1>
<script>document.cookie = "KeyPairId=TESTKEY; path=/";</script>
<img src="/img/a.png" width="400" height="400">
<img src="/img/b.png" width="400" height="400">
<img src="/img/c.png" width="400" height="400">
</body></html>""").encode("utf-8")

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/gate.html":
            self.send_response(200); self.send_header("Content-Type","text/html"); self.end_headers()
            self.wfile.write(PAGE); return
        if self.path.startswith("/img/"):
            if "KeyPairId=TESTKEY" in self.headers.get("Cookie",""):
                self.send_response(200); self.send_header("Content-Type","image/png")
                self.end_headers(); self.wfile.write(PNG)
            else:
                self.send_response(403); self.end_headers(); self.wfile.write(b"MissingKey")
            return
        self.send_response(404); self.end_headers()
    def log_message(self,*a): pass

class Server(ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True
with Server(("127.0.0.1", 8767), H) as s:
    s.serve_forever()
