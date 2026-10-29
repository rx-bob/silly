#!/usr/bin/env python3
"""Local protocol fixture. No outbound network or curl subprocesses."""
import http.server
import json
import os
import socket
import socketserver
import ssl
import struct
import sys
import threading
import time


order_lock = threading.Lock()
order_counter = 0


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def do_GET(self):
        try:
            self.respond()
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
            self.close_connection = True

    def respond(self):
        if self.path in ("/hold", "/delay"):
            time.sleep(2 if self.path == "/hold" else 0.7)
        body = b"hello\x00world"
        if self.path.startswith("/order/"):
            global order_counter
            with order_lock:
                order_counter = 0 if self.path == "/order/reset" else order_counter + 1
                body = str(order_counter).encode("ascii")
        if self.path == "/large":
            body = bytes(index % 251 for index in range(131072))
        if self.path in ("/idle", "/total"):
            body = b"abcdefghij"
        self.send_response(200)
        self.send_header("Content-Length", "100" if self.path == "/reset" else str(len(body)))
        self.send_header("X-Fixture", "local")
        if self.path == "/headers":
            self.send_header("X-Large", "x" * 8192)
        self.end_headers()
        if self.path == "/reset":
            self.wfile.write(b"short")
            self.wfile.flush()
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            self.close_connection = True
            self.connection.close()
            return
        if self.path in ("/idle", "/total"):
            for byte in body:
                self.wfile.write(bytes([byte]))
                self.wfile.flush()
                time.sleep(0.7 if self.path == "/idle" else 0.06)
            return
        self.wfile.write(body)
        self.wfile.flush()


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, *_):
        pass


class Stall(socketserver.BaseRequestHandler):
    def handle(self):
        time.sleep(2)


stall = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Stall)
stall.daemon_threads = True
threading.Thread(target=stall.serve_forever, daemon=True).start()
refused = socket.socket()
refused.bind(("127.0.0.1", 0))
refused_port = refused.getsockname()[1]
refused.close()
plain = Server(("127.0.0.1", 0), Handler)
secure = Server(("127.0.0.1", 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[2], sys.argv[3])
secure.socket = context.wrap_socket(secure.socket, server_side=True)
for server in (plain, secure):
    threading.Thread(target=server.serve_forever, daemon=True).start()
with open(sys.argv[1], "w", encoding="ascii") as ready:
    json.dump({"http": plain.server_port, "https": secure.server_port,
               "refused": refused_port, "stall": stall.server_address[1]}, ready)
while True:
    time.sleep(1)
