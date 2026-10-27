// Framing compatibility copies preserve decoded bytes, not stale chunk framing.
namespace promptnook_snapshot_cases;

import silly from "..";
import snapshot from "../examples/promptnook_contract";

import std;

fn fidelity(request: silly::Request) {
    let owned = promptnook_adapters::snapshot(request);
    assert(owned.error == promptnook_adapters::SnapshotError.None);
    assert(find(owned.bytes, "Transfer-Encoding:") < 0);
    assert(find(owned.bytes, "Trailer:") < 0);
    assert(find(owned.bytes, "Expect:") < 0);
    var fields: silly::HeaderView[>..] = [];
    let parsed = silly::parse_head(owned.bytes, fields, silly::Limits {
        });
    assert(parsed.result == silly::HeadResult.Complete);
    assert(parsed.framing == silly::BodyFraming.Fixed);
    assert(parsed.content_length == 5);
    assert(parsed.target == "/api/ideas/a%2Fb?key=&key=two+words");
    let restored = silly::Request {
        method: parsed.method,
        target: parsed.target,
        headers: fields,
        body_state: silly::RequestBody.Buffered {
            bytes: owned.bytes[parsed.head_bytes..]
        },
        ..
    };
    assert(silly::header_raw(restored, "authorization").value == "Bearer inert \t");
    assert(silly::header(restored, "authorization").value == "Bearer inert");
    assert(silly::header(restored, "X-Empty").present);
    assert(silly::header(restored, "X-Empty").value.len == 0);
    assert(!silly::header(restored, "X-Absent").present);
    var repeated = silly::header_values(restored, "X-Repeat", silly::HeaderValueMode.Wire);
    assert(silly::next_header(repeated).value == " one ");
    assert(silly::next_header(repeated).value == "\ttwo\t");
    assert(!silly::next_header(repeated).present);
    let body: u8[5] = ['a', 0, 255, '\r', '\n'];
    assert(owned.bytes[parsed.head_bytes..] == body);
    var reader = silly::new_body_reader(parsed.framing, parsed.content_length, silly::BodyLimits {
        });
    var decoded: u8[16] = [0; 16];
    let result = silly::read_body(reader, owned.bytes[parsed.head_bytes..], decoded, 1000);
    assert(result.status == silly::BodyStatus.Complete);
    assert(result.produced == body.len);
    assert(decoded[..result.produced] == body);
    assert(promptnook_adapters::snapshot(request, owned.bytes.len).error == promptnook_adapters::SnapshotError.None);
    let limited = promptnook_adapters::snapshot(request, owned.bytes.len - 1);
    assert(limited.error == promptnook_adapters::SnapshotError.Limit);
    assert(limited.bytes.len == 0);
}

fn chunked() {
    let raw = str("POST /api/ideas/a%2Fb?key=&key=two+words HTTP/1.1\r\nHost: fixture.test\r\n"
        , "Transfer-Encoding: chunked\r\nTrailer: X-End\r\nExpect: 100-continue\r\n"
        , "Authorization: Bearer inert \t\r\nX-Empty:\r\nX-Repeat: one \r\nX-Repeat:\ttwo\t\r\n\r\n");
    var fields: silly::HeaderView[>..] = [];
    let parsed = silly::parse_head(raw, fields, silly::Limits {
        });
    assert(parsed.result == silly::HeadResult.Complete);
    let wire: u8[23] = ['5', '\r', '\n', 'a', 0, 255, '\r', '\n', '\r', '\n', '0', '\r', '\n',
        'X', '-', 'E', 'n', 'd', ':', 'x', '\r', '\n', '\r'];
    var encoded: u8[>..] = [];
    encoded.append(wire);
    encoded.push('\n');
    var reader = silly::new_body_reader(parsed.framing, parsed.content_length, silly::BodyLimits {
        });
    var body: u8[32] = [0; 32];
    let decoded = silly::read_body(reader, encoded, body, 1000);
    assert(decoded.status == silly::BodyStatus.Complete);
    assert(decoded.produced == 5);
    fidelity(silly::Request {
            method: parsed.method,
            target: parsed.target,
            headers: fields,
            body_framing: parsed.framing,
            body_state: silly::RequestBody.Buffered {
                bytes: body[..decoded.produced]
            },
            ..
        });
}

fn invalid() {
    let host = [silly::HeaderView {
            name: "Host",
            value: " fixture.test"
        }];
    var request = silly::Request {
        method: "GET",
        target: "/",
        headers: host,
        ..
    };
    assert(promptnook_adapters::snapshot(request).error == promptnook_adapters::SnapshotError.None);
    assert(promptnook_adapters::snapshot(request, -1).error == promptnook_adapters::SnapshotError.Limit);
    assert(promptnook_adapters::snapshot(request, 131073).error == promptnook_adapters::SnapshotError.Limit);
    request.target = "/bad\r\nInjected: value";
    let bad = promptnook_adapters::snapshot(request);
    assert(bad.error == promptnook_adapters::SnapshotError.InvalidRequest);
    assert(bad.bytes.len == 0);
    request.target = "/ HTTP/1.1\r\nHost: fixture.test\r\n\r\nGET /";
    assert(promptnook_adapters::snapshot(request).error == promptnook_adapters::SnapshotError.InvalidRequest);
    request.target = "/";
    request.body_state = silly::RequestBody.Streamed;
    assert(promptnook_adapters::snapshot(request).error == promptnook_adapters::SnapshotError.BodyUnavailable);
    request.body_state = silly::RequestBody.Failed {
        error: silly::BodyError.Disconnected
    };
    assert(promptnook_adapters::snapshot(request).error == promptnook_adapters::SnapshotError.BodyUnavailable);
    let invalid = [silly::HeaderView {
            name: "Host",
            value: "fixture.test\r\nInjected: true"
        }];
    request.headers = invalid;
    request.body_state = silly::RequestBody.Buffered {
        bytes: ""
    };
    assert(promptnook_adapters::snapshot(request).error == promptnook_adapters::SnapshotError.InvalidRequest);
}

fn fixed_and_limits() {
    let headers = [
        silly::HeaderView {
            name: "Host",
            value: " fixture.test"
        },
        silly::HeaderView {
            name: "content-length",
            value: " 9999"
        },
    ];
    let request = silly::Request {
        method: "POST",
        target: "/",
        headers: headers,
        body_framing: silly::BodyFraming.Fixed,
        body_state: silly::RequestBody.Buffered {
            bytes: ""
        },
        ..
    };
    let owned = promptnook_adapters::snapshot(request);
    assert(owned.error == promptnook_adapters::SnapshotError.None);
    assert(find(owned.bytes, "9999") < 0);
    assert(ends_with(owned.bytes, "Content-Length: 0\r\n\r\n"));
    var many: silly::HeaderView[>..] = [];
    for index in 129 {
        many.push(silly::HeaderView {
                name: "X-Field",
                value: ""
            });
    }
    let overflow = promptnook_adapters::snapshot(silly::Request {
            method: "GET",
            target: "/",
            headers: many,
            ..
        });
    assert(overflow.error == promptnook_adapters::SnapshotError.Limit);
    assert(overflow.bytes.len == 0);
    let body: u8[256] = [0; 256];
    let oversized = promptnook_adapters::snapshot(silly::Request {
            method: "POST",
            target: "/",
            headers: headers,
            body_state: silly::RequestBody.Buffered {
                bytes: body
            },
            ..
        }, 255);
    assert(oversized.error == promptnook_adapters::SnapshotError.Limit);
    assert(oversized.bytes.len == 0);
}

fn run() {
    chunked();
    invalid();
    fixed_and_limits();
}
