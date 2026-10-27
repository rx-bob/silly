// MIME policy and conditional metadata share the exact opened representation with transfer bytes.
namespace static_metadata_test;

import silly from "..";

import std;

import.body_socket_fixture;
import.connection_socket_fixture;
import.static_metadata_fixture;
import.static_metadata_server;

const MODIFIED = "Sun, 06 Nov 1994 08:49:37 GMT";

fn exchange(port: i32, method: u8[:], path: u8[:], fields: u8[:]) -> u8[>..] {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, connection_socket::request(method, path, 1,
        str(fields, "Connection: close\r\n")));
    let result = body_socket::receive_closed(socket);
    silly_transport::close(socket);
    return result;
}

fn check(response: u8[:], status: i32, length: i64, mime: u8[:], body: u8[:]) {
    assert(starts_with(response, str("HTTP/1.1 ", status, " ")));
    let end = find(response, "\r\n\r\n");
    assert(end > 0);
    let headers = response[..end + 2];
    assert(find(headers, str("Content-Length: ", length, "\r\n")) >= 0);
    assert(find(headers, "Transfer-Encoding:") < 0);
    assert(find(headers, str("Content-Type: ", mime, "\r\n")) >= 0);
    assert(find(headers, str("Last-Modified: ", MODIFIED, "\r\n")) >= 0);
    assert(find(headers, str("ETag: W/\"portal-", length, "\"\r\n")) >= 0);
    assert(response[end + 4..] == body);
}

struct MimeCase {
    path: const u8[:],
    mime: const u8[:],
    body: const u8[:]
}

fn mime_files(port: i32) {
    const wasm: u8[8] = [0, 'a', 's', 'm', 1, 0, 0, 0];
    const binary: u8[4] = [0, 255, 1, 2];
    const cases = [
        MimeCase {
            path: "/index.html",
            mime: "text/html; charset=utf-8",
            body: "<p>x</p>"
        },
        MimeCase {
            path: "/module.mjs",
            mime: "text/javascript; charset=utf-8",
            body: "export{}"
        },
        MimeCase {
            path: "/style.css",
            mime: "text/css; charset=utf-8",
            body: "a{}"
        },
        MimeCase {
            path: "/code.wasm",
            mime: "application/wasm",
            body: wasm
        },
        MimeCase {
            path: "/note.txt",
            mime: "text/plain; charset=utf-8",
            body: "hi\n"
        },
        MimeCase {
            path: "/opaque.bin",
            mime: "application/octet-stream",
            body: binary
        },
        MimeCase {
            path: "/empty.txt",
            mime: "text/plain; charset=utf-8",
            body: ""
        },
        MimeCase {
            path: "/override.bin",
            mime: "application/x-custom",
            body: binary
        },
    ];
    for item in cases {
        let response = exchange(port, "GET", item.path, "");
        check(response, 200, item.body.len, item.mime, item.body);
        let head = exchange(port, "HEAD", item.path, "");
        check(head, 200, item.body.len, item.mime, "");
    }
}

struct ConditionCase {
    headers: const u8[:],
    status: i32
}
const CONDITIONS = [
    ConditionCase {
        headers: "If-None-Match: W/\"portal-8\"\r\n",
        status: 304
    },
    ConditionCase {
        headers: "If-None-Match: \"portal-8\"\r\n",
        status: 304
    },
    ConditionCase {
        headers: "If-None-Match: \"other\", W/\"portal-8\"\r\n",
        status: 304
    },
    ConditionCase {
        headers: "If-None-Match: *\r\n",
        status: 304
    },
    ConditionCase {
        headers: "If-Modified-Since: Sun, 06 Nov 1994 08:49:37 GMT\r\n",
        status: 304
    },
    ConditionCase {
        headers: "If-Modified-Since: Mon, 07 Nov 1994 08:49:37 GMT\r\n",
        status: 304
    },
    ConditionCase {
        headers: "If-Modified-Since: Sat, 05 Nov 1994 08:49:37 GMT\r\n",
        status: 200
    },
    ConditionCase {
        headers: "If-Modified-Since: not a date\r\n",
        status: 200
    },
    ConditionCase {
        headers: "If-Modified-Since: Sun, 31 Feb 1994 08:49:37 GMT\r\n",
        status: 200
    },
    ConditionCase {
        headers: "If-None-Match: \"different\"\r\nIf-Modified-Since: Mon, 07 Nov 1994 08:49:37 GMT\r\n",
        status: 200
    },
    ConditionCase {
        headers: "If-None-Match: malformed\r\nIf-Modified-Since: Mon, 07 Nov 1994 08:49:37 GMT\r\n",
        status: 200
    },
    ConditionCase {
        headers: "If-None-Match: W/\"portal-8\"\r\nIf-Modified-Since: nonsense\r\n",
        status: 304
    },
    ConditionCase {
        headers: "If-None-Match: \"portal-8\", broken\r\n",
        status: 200
    },
    ConditionCase {
        headers: "If-None-Match: \"other\"\r\nIf-None-Match: \"portal-8\"\r\n",
        status: 304
    },
];

fn overrides(port: i32) {
    check(exchange(port, "GET", "/plain.txt", ""), 200, 3, "text/plain", "hi\n");
    let response = exchange(port, "GET", "/supplied.txt", "");
    assert(starts_with(response, "HTTP/1.1 200 "));
    assert(find(response, "ETag: \"given\"\r\n") >= 0);
    assert(ends_with(response, "\r\n\r\nhi\n"));
    let cached = exchange(port, "GET", "/supplied.txt", "If-None-Match: W/\"given\"\r\n");
    assert(starts_with(cached, "HTTP/1.1 304 "));
    assert(find(cached, "ETag: \"given\"\r\n") >= 0);
    assert(find(cached, "Content-Length: 3\r\n") >= 0);
    assert(ends_with(cached, "\r\n\r\n"));
}

fn conditional(port: i32) {

    for item in CONDITIONS {
        let response = exchange(port, "GET", "/index.html", item.headers);
        let body = if item.status == 200 {
            "<p>x</p>"
        } else {
            ""
        };
        check(response, item.status, 8, "text/html; charset=utf-8", body);
        let head = exchange(port, "HEAD", "/index.html", item.headers);
        check(head, item.status, 8, "text/html; charset=utf-8", "");
    }
}

fn persistent(port: i32) {
    var socket = body_socket::connect(port);
    var pipeline: u8[>..] = [];
    pipeline.append(connection_socket::request("GET", "/index.html"));
    pipeline.append(connection_socket::request("HEAD", "/note.txt"));
    pipeline.append(connection_socket::request("GET", "/index.html", 1,
        "If-None-Match: W/\"portal-8\"\r\n"));
    pipeline.append(connection_socket::request("GET", "/style.css", 1, "Connection: close\r\n"));
    body_socket::send_bytes(socket, pipeline);
    check(connection_socket::receive(socket), 200, 8, "text/html; charset=utf-8", "<p>x</p>");
    check(connection_socket::receive(socket, true), 200, 3, "text/plain; charset=utf-8", "");
    check(connection_socket::receive(socket, true), 304, 8, "text/html; charset=utf-8", "");
    check(connection_socket::receive(socket), 200, 3, "text/css; charset=utf-8", "a{}");
    connection_socket::closed(socket);
    silly_transport::close(socket);
}

fn legacy(port: i32) {
    var socket = body_socket::connect(port);
    body_socket::send_bytes(socket, connection_socket::request("GET", "/index.html", 0));
    let response = body_socket::receive_closed(socket);
    silly_transport::close(socket);
    connection_socket::exact(response, 0, 200, "<p>x</p>");
    assert(find(response, "Content-Length: 8\r\n") >= 0);
    assert(find(response, "Transfer-Encoding:") < 0);
    assert(find(response, "Last-Modified: Sun, 06 Nov 1994 08:49:37 GMT\r\n") >= 0);
    assert(find(response, "ETag: W/\"portal-8\"\r\n") >= 0);
}

fn default_validator(port: i32) {
    let response = exchange(port, "GET", "/default.txt", "");
    assert(starts_with(response, "HTTP/1.1 200 "));
    let start = find(response, "ETag: ");
    assert(start > 0);
    let end = find(response[start + 6..], "\r\n");
    assert(end > 0);
    let tag = response[start + 6..start + 6 + end];
    assert(starts_with(tag, "W/\""));
    assert(ends_with(tag, "\""));
    assert(ends_with(response, "\r\n\r\ndefault!\n"));
    let cached = exchange(port, "GET", "/default.txt", str("If-None-Match: ", tag, "\r\n"));
    assert(starts_with(cached, "HTTP/1.1 304 "));
    assert(find(cached, str("ETag: ", tag, "\r\n")) >= 0);
    assert(find(cached, "Content-Length: 9\r\n") >= 0);
    assert(ends_with(cached, "\r\n\r\n"));
}

fn replacement(port: i32) {
    let response = exchange(port, "GET", "/replace.txt", "");
    check(response, 200, 11, "text/plain; charset=utf-8", "old-content");
    // Validator hook replaces the path after metadata has been read from the original descriptor.
    let next = exchange(port, "GET", "/replace.txt", "");
    assert(find(next, "Content-Length: 15\r\n") >= 0);
    assert(find(next, "Last-Modified: Mon, 07 Nov 1994 08:49:37 GMT\r\n") >= 0);
    assert(ends_with(next, "\r\n\r\nnew-data-longer"));
}

fn finish(executor: silly::FileExecutor&) {
    assert(silly::stop_file_executor(executor).ok);
    let deadline = body_socket::now() + 10000;
    while body_socket::now() < deadline {
        let result = silly::finish_file_executor(executor);
        assert(result.error == 0);
        if result.complete {
            return;
        }
        const fds: i32[1] = [-1];
        const interests: i32[1] = [0];
        var events: i32[1] = [0];
        silly_transport::poll(fds, interests, events, 1);
    }
    abort("metadata executor did not finish");
}

fn run() {
    qlimit<metadata_server::Started>(1);
    qlimit<metadata_server::Stopped>(1);
    var path: u8[128] = [0; 128];
    let size = static_fixture::silly_metadata_fixture_create(path);
    assert(size > 0);
    var root = silly::open_file_root(path[..size]);
    assert(root.ok);
    var pool = silly::start_file_executor(silly::FileExecutorOptions {
            workers: 2,
            capacity: 4,
            chunk_bytes: 3,
            ..
        });
    assert(pool.ok);
    var listener = silly_transport::listen("127.0.0.1", 0, 8);
    assert(listener.status == silly_transport::IoStatus.Ready);
    let port = silly_transport::local_port(listener.descriptor);
    assert(port.status == silly_transport::IoStatus.Ready);
    var wake = silly_transport::wake_pair();
    assert(wake.status == silly_transport::IoStatus.Ready);
    let owner = thread_spawn(metadata_server::server, listener.descriptor.fd, wake.reader.fd, pool.executor, root.root);
    listener.descriptor.fd = -1;
    wake.reader.fd = -1;
    let started, ready = qget<metadata_server::Started>(10000);
    assert(ready);
    mime_files(port.count as i32);
    persistent(port.count as i32);
    legacy(port.count as i32);
    overrides(port.count as i32);
    conditional(port.count as i32);
    default_validator(port.count as i32);
    replacement(port.count as i32);
    assert(silly_transport::notify(wake.writer).status == silly_transport::IoStatus.Ready);
    let stopped, done = qget<metadata_server::Stopped>(10000);
    assert(done);
    assert(stopped.ok);
    assert(thread_wait(owner));
    silly_transport::close(wake.writer);
    finish(pool.executor);
    assert(silly::close_file_root(root.root).ok);
    assert(static_fixture::silly_metadata_fixture_remove() == 0);
}

fn::main() {
    static_metadata_test::run();
    print("static MIME, HEAD, validators, conditional precedence and opened metadata passed");
}
