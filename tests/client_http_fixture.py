#!/usr/bin/env python3
"""Local methods, upload, response-metadata and content-decoding fixture."""
import gzip
import http.server
import json
import sys
import threading
import time
import zlib

PAYLOAD = b"compressed\x00payload\xff" * 128
GZIP = gzip.compress(PAYLOAD, mtime=0)
DEFLATE = zlib.compress(PAYLOAD)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            result = bytearray()
            while True:
                count = int(self.rfile.readline().split(b";", 1)[0], 16)
                if count == 0:
                    while self.rfile.readline() != b"\r\n":
                        pass
                    return bytes(result)
                result.extend(self.rfile.read(count))
                assert self.rfile.read(2) == b"\r\n"
        return self.rfile.read(int(self.headers.get("Content-Length", "0")))

    def dispatch(self):
        try:
            self.respond()
        except (BrokenPipeError, ConnectionResetError, ValueError):
            self.close_connection = True

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_OPTIONS = do_HEAD = do_PROPFIND = dispatch

    def respond(self):
        path = self.path.split("?", 1)[0]
        if path == "/duplex":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            prefix = b"p" * 32768
            self.wfile.write(f"{len(prefix):x}\r\n".encode() + prefix + b"\r\n")
            self.wfile.flush()
            incoming = self.body()
            self.wfile.write(f"{len(incoming):x}\r\n".encode() + incoming + b"\r\n0\r\n\r\n")
            self.wfile.flush()
            return
        if path == "/slow-upload":
            time.sleep(0.15)
        incoming = self.body()
        status, body, fields = 200, b"ok", []
        chunked = False
        if path in ("/echo", "/slow-upload"):
            body = incoming
            fields = [("X-Method", self.command),
                      ("X-Request-Type", self.headers.get("Content-Type", "none")),
                      ("X-Accept-Encoding", self.headers.get("Accept-Encoding", "none")),
                      ("X-Repeat", "|".join(self.headers.get_all("X-Repeat", []))),
                      ("X-Empty", "present" if "X-Empty" in self.headers else "absent"),
                      ("X-Request-TE", self.headers.get("Transfer-Encoding", "none")),
                      ("X-Request-Length", self.headers.get("Content-Length", "none"))]
        elif path == "/interim":
            self.wfile.write(b"HTTP/1.1 100 Continue\r\nX-Interim: first\r\n\r\n")
            self.wfile.write(b"HTTP/1.1 103 Early Hints\r\nLink: </a>\r\n\r\n")
            body = b"final\x00bytes"
            fields = [("X-Repeat", "first"), ("X-Repeat", "second"), ("Content-Type", "application/octet-stream")]
        elif path in ("/gzip-large", "/deflate-large"):
            expanded = bytes(index % 251 for index in range(131072))
            coding = "gzip" if path == "/gzip-large" else "deflate"
            body = gzip.compress(expanded, mtime=0) if coding == "gzip" else zlib.compress(expanded)
            fields = [("Content-Encoding", coding)]
            chunked = True
        elif path in ("/gzip", "/gzip-chunked", "/gzip-bytes"):
            body = GZIP
            if path != "/gzip-bytes":
                fields.append(("Content-Encoding", "gzip"))
            chunked = path.endswith("chunked")
        elif path in ("/deflate", "/deflate-chunked", "/deflate-bytes"):
            body = DEFLATE
            if path != "/deflate-bytes":
                fields.append(("Content-Encoding", "deflate"))
            chunked = path.endswith("chunked")
        elif path == "/gzip-empty":
            body = gzip.compress(b"", mtime=0)
            fields = [("Content-Encoding", "gzip")]
        elif path == "/gzip-empty-members":
            body = gzip.compress(b"", mtime=0) * 256 + gzip.compress(b"last", mtime=0)
            fields = [("Content-Encoding", "gzip")]
        elif path == "/switch":
            self.wfile.write(b"HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: test\r\n\r\n")
            self.wfile.flush()
            self.close_connection = True
            return
        elif path == "/gzip-concatenated":
            body = GZIP + GZIP
            fields = [("Content-Encoding", "gzip")]
        elif path == "/gzip-crc":
            damaged = bytearray(GZIP)
            damaged[-8] ^= 1
            body = bytes(damaged)
            fields = [("Content-Encoding", "gzip")]
        elif path == "/truncated-deflate":
            body = DEFLATE[:-2]
            fields = [("Content-Encoding", "deflate")]
        elif path == "/truncated-gzip":
            body = GZIP[:-8]
            fields = [("Content-Encoding", "gzip")]
        elif path == "/bad-gzip":
            body = b"not gzip at all"
            fields = [("Content-Encoding", "gzip")]
        elif path == "/head":
            body = b"x" * 99
            fields = [("Content-Encoding", "gzip"), ("Content-Type", "application/test")]
        elif path in ("/204", "/304"):
            status = int(path[1:])
            body = b"" if status == 204 else b"x" * 99
            fields = [("Content-Encoding", "gzip")]
        elif path == "/error":
            status, body = 418, b"error\x00\xff"
        elif path == "/redirect":
            status, body, fields = 302, b"redirect body", [("Location", "/auth?redirected=1")]
        elif path == "/auth":
            body = self.headers.get("Authorization", "none").encode()
        self.send_response(status)
        for name, value in fields:
            self.send_header(name, value)
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Trailer", "X-Trailer")
        else:
            self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command == "HEAD" or status in (204, 304):
            return
        if chunked:
            for at in range(0, len(body), 7):
                chunk = body[at:at + 7]
                self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
            self.wfile.write(b"0\r\nX-Trailer: excluded\r\n\r\n")
        else:
            self.wfile.write(body)
        self.wfile.flush()


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, *_):
        pass


server = Server(("127.0.0.1", 0), Handler)
with open(sys.argv[1], "w", encoding="ascii") as ready:
    json.dump({"http": server.server_port}, ready)
server.serve_forever()
