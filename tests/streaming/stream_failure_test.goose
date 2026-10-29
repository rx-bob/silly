// Owned mapped failures pass through shared validation only before wire commitment.
namespace stream_failure_test;

import silly from "../../";

import std;

fn render(method: u8[:], cap: i64 = 4096) {
    var head: u8[8192] = [0; 8192];
    var body: u8[4096] = [0; 4096];
    var empty: u8[1] = [0];
    var hooks = silly::HookState {
    };
    var connection = silly::Connection {
    };
    connection.completion.method.append(method);
    var mapped = silly::StreamFailureResponse {
        selected: true,
        status: 503,
        ..
    };
    mapped.content_type.append("text/plain");
    mapped.body.append("mapped upstream failure");
    silly::render_stream_failure(connection, silly::ConnectionBuffers {
            input: empty,
            head: head,
            body: body,
            request: empty,
            staging: empty,
            hooks: hooks,
        }, silly::ServerOptions {
            limits: silly::Limits {
                output_bytes_max: cap,
                ..
            },
            ..
        }, mapped);
    assert(connection.phase == silly::ConnectionPhase.Writing);
    assert(connection.close_after_reply);
    assert(connection.head_sent == 0);
    if cap < mapped.body.len {
        assert(connection.completion.status == 500);
        assert(connection.body_bytes == 0);
        return;
    }
    assert(connection.completion.status == 503);
    assert(find(head[..connection.head_bytes], " 503 ") >= 0);
    assert(find(head[..connection.head_bytes], "Content-Type: text/plain") >= 0);
    if method == "HEAD" {
        assert(connection.body_bytes == 0);
    } else {
        assert(body[..connection.body_bytes] == "mapped upstream failure");
    }
}

fn::main() {
    stream_failure_test::render("GET");
    stream_failure_test::render("HEAD");
    stream_failure_test::render("GET", 1);
    print("mapped stream failure response validation passed");
}
