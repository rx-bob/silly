#!/usr/bin/env python3
"""Disposable proxy upstream and downstream integration driver; no external targets."""
import base64
import gzip
import http.client
import http.server
import json
import os
import pathlib
import socket
import socketserver
import struct
import subprocess
import sys
import tempfile
import threading
import time

PAYLOAD = bytes(range(256)) * 512
COMPRESSED = gzip.compress(PAYLOAD, mtime=0)
PREFIX = b"p" * 262144


class Upstream(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):
        pass

    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            output = bytearray()
            while True:
                line = self.rfile.readline()
                if not line:
                    raise ConnectionResetError()
                size = int(line.split(b";", 1)[0], 16)
                if size == 0:
                    while self.rfile.readline() != b"\r\n":
                        pass
                    return bytes(output)
                output.extend(self.rfile.read(size))
                if self.rfile.read(2) != b"\r\n":
                    raise ConnectionResetError()
        return self.rfile.read(int(self.headers.get("Content-Length", "0")))

    def fixed(self, body, code=200, headers=()):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
            self.wfile.flush()

    def dispatch(self):
        try:
            self.respond()
        except (BrokenPipeError, ConnectionResetError, ValueError, OSError):
            self.close_connection = True

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = dispatch

    def respond(self):
        path = self.path.split("?", 1)[0]
        if path == "/stall-header":
            time.sleep(2)
            self.fixed(b"late")
            return
        if path == "/stall-upload":
            time.sleep(2)
            self.body()
            self.fixed(b"uploaded")
            return
        if path == "/stall-body":
            self.send_response(200)
            self.send_header("Content-Length", "1000000")
            self.end_headers()
            self.wfile.write(b"initial")
            self.wfile.flush()
            time.sleep(2)
            self.wfile.write(b"later")
            return
        if path == "/reset":
            self.send_response(200)
            self.send_header("Content-Length", "1000000")
            self.end_headers()
            self.wfile.write(b"before-reset")
            self.wfile.flush()
            time.sleep(0.15)
            self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            self.close_connection = True
            return
        if path == "/duplex":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(f"{len(PREFIX):x}\r\n".encode() + PREFIX + b"\r\n")
            self.wfile.flush()
            body = self.body()
            self.wfile.write(f"{len(body):x}\r\n".encode() + body + b"\r\n0\r\n\r\n")
            self.wfile.flush()
            return
        self.body()
        if path == "/health":
            self.fixed(b"healthy")
        elif path == "/gzip":
            self.fixed(COMPRESSED, headers=[("Content-Encoding", "gzip"), ("Content-Type", "application/octet-stream")])
        elif path == "/audit":
            self.fixed(b"audited", headers=[("X-Audit", "visible")])
        elif path == "/large":
            self.fixed(PAYLOAD)
        elif path == "/empty":
            self.fixed(b"", 204)
        elif path == "/head":
            self.send_response(200)
            self.send_header("Content-Length", "123")
            self.send_header("Content-Encoding", "gzip")
            self.end_headers()
        else:
            # Read-body capture is handled by echo's specialized implementation below.
            self.fixed(b"unknown", 404)


class EchoUpstream(Upstream):
    def respond(self):
        if self.path.startswith("/echo"):
            body = self.body()
            response = json.dumps({"method": self.command, "path": self.path,
                "headers": list(self.headers.raw_items()), "body": base64.b64encode(body).decode()},
                separators=(",", ":")).encode()
            self.fixed(response, headers=[("Content-Type", "application/json"),
                ("Connection", "X-Response-Hop, close"), ("X-Response-Hop", "secret"),
                ("Set-Cookie", "a=1"), ("Set-Cookie", "b=2")])
        else:
            super().respond()


class ThreadServer(http.server.ThreadingHTTPServer):
    daemon_threads = True


class Stall(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(5)
        try:
            while self.request.recv(4096):
                pass
        except OSError:
            pass


class StallServer(socketserver.ThreadingTCPServer):
    daemon_threads = True


def exchange(port, path, method="GET", body=None, headers=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    connection.request(method, path, body=body, headers={"Connection": "close", **(headers or {})})
    response = connection.getresponse()
    data = response.read()
    result = response.status, response.getheaders(), data
    connection.close()
    return result


def fields(headers):
    return {name.lower(): value for name, value in headers}


def healthy(port):
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        try:
            status, _, body = exchange(port, "/health")
            if status == 200 and body == b"healthy":
                return
        except (OSError, http.client.HTTPException):
            pass
        time.sleep(0.01)
    raise AssertionError("upstream capacity was not reclaimed after downstream completion/cancellation")


def echo_cases(port, upstream):
    binary = bytes(range(256)) * 1024
    for path, auth, host in [("/echo?x=1&x=2&empty=", None, f"127.0.0.1:{upstream}"),
                             ("/incoming/echo", "Bearer incoming", "downstream.example"),
                             ("/override/echo", "Bearer supplied", "custom.upstream")]:
        status, headers, body = exchange(port, path, "PATCH", binary, {
            "Host": "downstream.example", "Authorization": "Bearer incoming",
            "X-Override": "incoming", "X-Request-Hop": "drop-me", "Connection": "X-Request-Hop, close",
            "X-End-To-End": "kept", "Content-Type": "application/octet-stream"})
        assert status == 200, (path, status, body)
        value = json.loads(body)
        seen = fields(value["headers"])
        assert value["method"] == "PATCH" and base64.b64decode(value["body"]) == binary
        assert seen.get("authorization") == auth, seen
        assert seen["host"] == host and seen["x-override"] == "configured", seen
        assert "x-request-hop" not in seen and seen["x-end-to-end"] == "kept", seen
        assert "x-response-hop" not in fields(headers)
        assert [v for n, v in headers if n.lower() == "set-cookie"] == ["a=1", "b=2"]
        if path.startswith("/echo?"):
            assert value["path"] == "/echo?x=1&x=2&empty="
    status, _, body = exchange(port, "/rewrite/nested?q=one&q=two", "PUT", b"rewrite")
    assert status == 200 and json.loads(body)["path"] == "/echo/nested?q=one&q=two"
    status, _, body = exchange(port, "/buffered", "POST", b"\x00buffered\xff")
    assert status == 200 and base64.b64decode(json.loads(body)["body"]) == b"\x00buffered\xff"
    # Unknown-length downstream body exercises dechunked upload and recomputed framing.
    status, _, body = exchange(port, "/echo", "POST", iter([b"chunk\x00", b"ed\xff"]))
    assert status == 200 and base64.b64decode(json.loads(body)["body"]) == b"chunk\x00ed\xff"


def response_cases(port):
    status, headers, body = exchange(port, "/gzip", headers={"Accept-Encoding": "gzip"})
    assert status == 200 and body == COMPRESSED and fields(headers)["content-encoding"] == "gzip"
    assert "content-length" not in fields(headers)
    status, headers, body = exchange(port, "/auto/gzip", headers={"Accept-Encoding": "gzip"})
    assert status == 200 and body == PAYLOAD
    assert "content-encoding" not in fields(headers) and "content-length" not in fields(headers)
    status, headers, body = exchange(port, "/head", "HEAD")
    assert status == 200 and body == b"" and fields(headers).get("content-length") == "123", (status, headers, body)
    status, _, body = exchange(port, "/empty")
    assert status == 204 and body == b""
    status, _, body = exchange(port, "/audit")
    assert status == 201 and body == b"audited"
    status, _, body = exchange(port, "/cap")
    assert status == 502 and body == b"upstream failure", (status, body)
    status, _, body = exchange(port, "/mapped")
    assert status == 599 and body == b"mapped failure", (status, body)
    status, _, body = exchange(port, "/__stats")
    assert status == 200 and body.split(b",")[:2] == [b"1", b"7"], body


def duplex(port):
    body = bytes(range(256)) * 4096
    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
    sock.settimeout(10)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 2048)
    sock.sendall(f"POST /duplex HTTP/1.1\r\nHost: localhost\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode())
    sock.sendall(body[:1])
    # A response must arrive before upload completion; ordinary forwarding is incremental.
    response = http.client.HTTPResponse(sock, method="POST")
    response.begin()
    assert response.status == 200
    # Let upstream output fill both bounded proxy stages while request input remains incomplete.
    time.sleep(0.1)
    failures = []
    def send():
        try:
            sock.sendall(body[1:])
        except OSError as error:
            failures.append(error)
    sender = threading.Thread(target=send)
    sender.start()
    time.sleep(0.1)
    received = response.read()
    sender.join(10)
    assert not sender.is_alive() and not failures
    assert received == PREFIX + body, (len(received), len(PREFIX + body))
    sock.close()


def reset_and_cancel(port):
    # Health retries can themselves fail admission while the previous slot is being released.
    # Each deliberate abort has its own retained proxy tag; unrelated cleanup cannot affect it.
    before = [int(value) for value in exchange(port, "/__stats")[2].split(b",")][6:15]
    assert before == [0] * 9, ("abort tags must start unused", before)
    sock = socket.create_connection(("127.0.0.1", port), timeout=5)
    sock.settimeout(5)
    sock.sendall(b"GET /reset HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    data = bytearray()
    while True:
        part = sock.recv(4096)
        if not part:
            break
        data.extend(part)
    sock.close()
    assert data.startswith(b"HTTP/1.1 200 ") and b"before-reset" in data, data
    assert data.count(b"HTTP/1.1") == 1 and not data.endswith(b"0\r\n\r\n"), data
    healthy(port)
    for path in ["/connect-stall", "/stall-upload", "/stall-header", "/stall-body"]:
        for _ in range(2):
            sock = socket.create_connection(("127.0.0.1", port), timeout=5)
            sock.settimeout(5)
            if path == "/stall-upload":
                request = b"POST /stall-upload HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1000000\r\n\r\nabc"
            else:
                request = f"GET {path} HTTP/1.1\r\nHost: localhost\r\n\r\n".encode()
            sock.sendall(request)
            if path == "/stall-body":
                assert sock.recv(1024).startswith(b"HTTP/1.1 200 ")
            else:
                time.sleep(0.05)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            sock.close()
            healthy(port)
    after = [int(value) for value in exchange(port, "/__stats")[2].split(b",")][6:15]
    assert after == [1] * 9, ("exactly one cancellation for each tagged aborted stream", after)


def run(executable, work):
    server = ThreadServer(("127.0.0.1", 0), EchoUpstream)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    stall = StallServer(("127.0.0.1", 0), Stall)
    threading.Thread(target=stall.serve_forever, daemon=True).start()
    reserved = socket.socket()
    reserved.bind(("127.0.0.1", 0))
    refused = reserved.getsockname()[1]
    reserved.close()
    ready = work / "ready"
    stop = work / "stop"
    env = dict(os.environ, SILLY_PROXY_UPSTREAM=f"http://127.0.0.1:{server.server_port}",
               SILLY_PROXY_REFUSED=f"http://127.0.0.1:{refused}",
               SILLY_PROXY_STALL=f"https://127.0.0.1:{stall.server_address[1]}",
               SILLY_PROXY_READY=str(ready), SILLY_PROXY_STOP=str(stop))
    process = subprocess.Popen([executable], env=env)
    shutdown_socket = None
    try:
        deadline = time.monotonic() + 10
        port = None
        while process.poll() is None and time.monotonic() < deadline:
            try:
                text = ready.read_text()
                if text and text.isdecimal() and 0 < int(text) <= 65535:
                    port = int(text)
                    break
            except FileNotFoundError:
                pass
            time.sleep(0.01)
        assert port is not None, ("proxy did not publish a complete port", process.poll())
        healthy(port)
        echo_cases(port, server.server_port)
        response_cases(port)
        duplex(port)
        reset_and_cancel(port)
        # Stop the server with an active response; fixture main must drain the client worker.
        shutdown_socket = socket.create_connection(("127.0.0.1", port), timeout=5)
        shutdown_socket.sendall(b"GET /stall-body HTTP/1.1\r\nHost: localhost\r\n\r\n")
        assert shutdown_socket.recv(1024).startswith(b"HTTP/1.1 200 ")
        print("proxy streaming, policies, framing, inspection and cancellation passed", flush=True)
    finally:
        stop.touch()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise
        if shutdown_socket is not None:
            shutdown_socket.close()
        server.shutdown()
        stall.shutdown()
    assert process.returncode == 0, process.returncode


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="silly-proxy-fixture-") as directory:
        run(sys.argv[1], pathlib.Path(directory))
