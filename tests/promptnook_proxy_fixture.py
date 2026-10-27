"""Disposable source-derived Portal/MCP contract upstreams; loopback only."""
import base64
import gzip
import http.client
import http.server
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import sys
import threading
import time

PAYLOAD = b"portal binary\x00\xff response" * 100
COMPRESSED = gzip.compress(PAYLOAD, mtime=0)


class Upstream(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def body(self):
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            result = bytearray()
            while True:
                size = int(self.rfile.readline().split(b";", 1)[0], 16)
                if not size:
                    assert self.rfile.readline() == b"\r\n"
                    return bytes(result)
                result.extend(self.rfile.read(size))
                assert self.rfile.readline() == b"\r\n"
        return self.rfile.read(int(self.headers.get("Content-Length", 0)))

    def do_GET(self):
        body = self.body()
        path = self.path.split("?", 1)[0]
        status, reason, payload, encoding = 200, None, b"", None
        if path == "/mcp-ok":
            assert self.headers.get("Authorization") == "Bearer inert-mcp-token", self.headers
            assert self.headers.get("Accept") == "application/json, text/plain;q=0.9, */*;q=0.8", self.headers
            payload = b"ok"
        elif path == "/mcp-redirect":
            status, payload = 302, b"redirect"
        elif path == "/mcp-forbidden":
            status, payload = 403, b"forbidden"
        elif path == "/mcp-auth":
            status, payload = 401, b"authentication required"
        elif path == "/mcp-error":
            status, reason, payload = 418, "Custom Teapot", b"not the reason phrase"
        elif path == "/mcp-large":
            payload = b"x" * 70000
        elif path.endswith("/gzip"):
            payload, encoding = COMPRESSED, "gzip"
        elif path.endswith("/audit"):
            status = 404
            payload = b'{"meta":{"response_kind":"lookup","lookup":{"identifier":"node-7"}},"error":{"message":"safe error","code":"NOT_FOUND"}}'
        elif path.endswith("/cap"):
            payload = b"x" * 5000
        else:
            payload = json.dumps({"method": self.command, "path": self.path,
                "headers": list(self.headers.items()), "body": base64.b64encode(body).decode()}).encode()
        self.send_response(status, reason)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        if path == "/mcp-redirect":
            self.send_header("Location", "/mcp-ok")
        if encoding:
            self.send_header("Content-Encoding", encoding)
        self.end_headers()
        try:
            self.wfile.write(payload)
        except (BrokenPipeError, ConnectionResetError):
            pass

    do_POST = do_GET
    do_PATCH = do_GET


def exchange(port, path, method="GET", body=None, headers=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    conn.putrequest(method, path, skip_host=True, skip_accept_encoding=True)
    supplied = headers or {}
    if not any(k.lower() == "host" for k in supplied):
        conn.putheader("Host", "portal.inert")
    for key, value in supplied.items():
        conn.putheader(key, value)
    if body is not None:
        conn.putheader("Content-Length", str(len(body)))
    conn.endheaders(body)
    response = conn.getresponse()
    value = (response.status, response.getheaders(), response.read())
    conn.close()
    return value


def echo(port, path, expected_path, auth=None, headers=None, method="GET", body=None):
    status, _, payload = exchange(port, path, method, body, headers)
    assert status == 200, (status, payload)
    result = json.loads(payload)
    seen = {k.lower(): v for k, v in result["headers"]}
    assert result["path"] == expected_path, result
    assert seen.get("authorization") == auth, seen
    assert seen["host"] == (headers or {}).get("Host", "portal.inert"), seen
    assert seen.get("user-agent") == (headers or {}).get("User-Agent", "Crystal"), seen
    if "Accept" in (headers or {}):
        assert seen.get("accept") == headers["Accept"], seen
    else:
        assert "accept" not in seen, seen
    assert result["method"] == method
    assert base64.b64decode(result["body"]) == (body or b"")
    return seen


def portal_cases(port):
    echo(port, "/portal-api/echo", "/api/admin/echo", "Bearer configured-token")
    echo(port, "/portal-api", "/api/admin/", "Bearer configured-token")
    echo(port, "/portal-api///echo?environment=secure&x=1&y=2&x=3&ENVIRONMENT=bad&empty&z=a+b&bad=%ZZ",
         "/secure/base/echo?x=1&x=3&y=2&empty=&z=a+b&bad=%25ZZ", "Bearer secure-token")
    echo(port, "/portal-api/echo?environment=incoming", "/api/admin/echo", "Bearer incoming",
         {"Authorization": "Bearer   incoming  ", "Host": "custom.inert", "User-Agent": "custom-agent", "Accept": "text/plain"})
    echo(port, "/portal-api/echo?environment=empty", "/api/admin/echo", "Bearer   incoming  ",
         {"Authorization": "Bearer   incoming  "})
    echo(port, "/portal-api/echo?environment=empty", "/api/admin/echo", "Basic inert", {"Authorization": "Basic inert"})
    echo(port, "/portal-api/echo?environment=incoming", "/api/admin/echo", "Basic inert", {"Authorization": "Basic inert"})
    echo(port, "/portal-api/echo?environment=axiom&environment=secure", "/api/admin/echo", "Bearer configured-token",
         {"Authorization": "Bearer ignored"}, "PATCH", b"body\x00\xff")
    echo(port, "/portal-api/echo?Environment=secure&x=one;x=two",
         "/api/admin/echo?x=one&x=two", "Bearer configured-token")
    echo(port, "/portal-api/echo", "/api/admin/echo", "Bearer configured-token", {"Accept": ""})
    status, _, body = exchange(port, "/portal-api/echo?environ%6dent=secure")
    assert status == 400 and json.loads(body)["message"] == "No URL configured for environment: secureaxiom"
    for selector in ["", "missing", "AXIOM"]:
        status, _, body = exchange(port, "/portal-api/echo?environment=" + selector)
        assert status == 400, (status, body)
        assert json.loads(body) == {"error": "Invalid environment",
            "message": "No URL configured for environment: " + selector}
    echo(port, "/portal-api/echo", "/legacy/echo", "Bearer inert-example-token", {"X-Test-Legacy": "1"})
    status, _, body = exchange(port, "/portal-api/echo?environment=secure", headers={"X-Test-Legacy": "1"})
    assert status == 400 and json.loads(body)["error"] == "Invalid environment"
    status, headers, body = exchange(port, "/portal-api/gzip")
    assert status == 200 and body == PAYLOAD
    assert "content-encoding" not in dict((k.lower(), v) for k, v in headers)
    for encoding in ["gzip", ""]:
        status, headers, body = exchange(port, "/portal-api/gzip", headers={"Accept-Encoding": encoding})
        assert status == 200 and body == COMPRESSED
        assert dict((k.lower(), v) for k, v in headers)["content-encoding"] == "gzip"
    status, _, body = exchange(port, "/portal-api/audit")
    assert status == 202 and json.loads(body)["meta"]["lookup"]["identifier"] == "node-7"
    status, _, body = exchange(port, "/portal-api/echo?environment=refused")
    assert status == 502 and json.loads(body)["error"] == "Portal backend proxy failure", body
    status, _, body = exchange(port, "/portal-api/echo?environment=mismatch")
    assert status == 502 and "certificate verify failed" in json.loads(body)["message"], body


def run(executable, directory):
    work = Path(directory)
    plain = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
    secure = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(work / "server.pem", work / "server.key")
    secure.socket = context.wrap_socket(secure.socket, server_side=True)
    for server in (plain, secure):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    refused = socket.socket()
    refused.bind(("127.0.0.1", 0))
    refused_port = refused.getsockname()[1]
    refused.close()
    ready, stop = work / "proxy-ready", work / "proxy-stop"
    ready.unlink(missing_ok=True)
    stop.unlink(missing_ok=True)
    env = dict(os.environ, PN_TEST_HTTP=f"http://127.0.0.1:{plain.server_port}",
        PN_TEST_HTTPS=f"https://localhost:{secure.server_port}",
        PN_TEST_MISMATCH=f"https://127.0.0.1:{secure.server_port}",
        PN_TEST_REFUSED=f"http://127.0.0.1:{refused_port}", PN_TEST_CA=str(work / "ca.pem"),
        PN_TEST_READY=str(ready), PN_TEST_STOP=str(stop))
    process = subprocess.Popen([executable], env=env)
    try:
        for _ in range(1000):
            if ready.exists() or process.poll() is not None:
                break
            time.sleep(.01)
        assert ready.exists(), ("consumer did not start", process.poll())
        portal_cases(int(ready.read_text()))
    finally:
        stop.touch()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        refused.close()
        plain.shutdown()
        secure.shutdown()
    assert process.returncode == 0, process.returncode
    print("PromptNook Portal/MCP HTTP/HTTPS consumer contracts passed", flush=True)


if __name__ == "__main__":
    run(sys.argv[1], sys.argv[2])
