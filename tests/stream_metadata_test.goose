namespace stream_metadata_test;

import chunk_writer from "../src";
import connection from "../src";
import headers from "../src";
import lifecycle_types from "../src";
import limits from "../src";
import response from "../src";
import response_wire_types from "../src";
import server_body from "../src";
import stream from "../src";
import stream_contract from "../src";
import stream_driver from "../src";
import stream_metadata from "../src";
import stream_transport from "../src";

import std;

struct State {
    mode: i64 = 0,
    calls: i64 = 0,
    cancelled: i64 = 0,
}
fn step(state: State&, event: silly::StreamEvent, out: silly::ChunkWriter&) -> silly::StreamStep {
    if event == silly::StreamEvent.Cancelled {
        state.cancelled += 1;
        return silly::StreamStep.Done;
    }
    state.calls += 1;
    if state.mode == 0 {
        return silly::StreamStep.Done;
    }
    if state.mode == 1 {
        assert(silly::append(out, "abc"));
        return silly::StreamStep.Chunk {
            flush: true,
            next: silly::Wake.Ready
        };
    }
    let metadata = out.metadata;
    guard metadata else {
        assert(false);
        return silly::StreamStep.Done;
    }
    metadata.ready = true;
    metadata.representation_length = 9;
    return silly::StreamStep.Wait {
        wake: silly::Wake.Ready
    };
}

fn advance(slot: silly::StreamSlot<State>&) {
    var head: u8[1024] = [0; 1024];
    var empty: u8[1] = [0];
    var hooks = silly::HookState {
    };
    var connection = silly::Connection {
    };
    silly::advance_stream_output(slot, connection, silly::ConnectionBuffers {
            input: empty,
            head: head,
            body: empty,
            request: empty,
            staging: empty,
            hooks: hooks,
        }, 0, step);
}

fn retention_limits() {
    var slot = silly::StreamSlot<State> {
    };
    var fields: silly::HeaderField[>..] = [];
    var bytes: u8[>..] = [];
    var output: u8[>..] = [];
    var response = silly::Response {
        limits: silly::Limits {
        },
        header_fields: fields,
        header_bytes: bytes,
        output: output,
        phase: silly::ResponsePhase.Prepared,
        ..
    };
    let options = silly::ResponseWireOptions {
        request_method: "GET",
        ..
    };
    for index in 129 {
        fields.push(silly::HeaderField {
                name_start: 0,
                name_bytes: 0,
                value_start: 0,
                value_bytes: 0
            });
    }
    assert(silly::retain_stream_head(slot, response, options, 1024) == silly::ResponseError.HeaderCountLimit);
    assert(slot.retained_fields.len == 0);
    fields.clear();
    for index in 16385 {
        bytes.push('x');
    }
    assert(silly::retain_stream_head(slot, response, options, 1024) == silly::ResponseError.HeaderBytesLimit);
    assert(slot.retained_headers.len == 0);
    bytes.clear();
    bytes.append("X-Testvalue");
    fields.push(silly::HeaderField {
            name_start: 0,
            name_bytes: 6,
            value_start: 6,
            value_bytes: 5
        });
    assert(silly::retain_stream_head(slot, response, options, 1024) == silly::ResponseError.None);
    assert(slot.request_method == "GET");
    bytes[0] = 'Y';
    fields[0].name_bytes = 1;
    assert(slot.retained_headers == "X-Testvalue");
    assert(slot.retained_fields[0].name_bytes == 6);
}

fn missing_metadata() {
    for mode in 2 {
        var slot = silly::StreamSlot<State> {
            deferred: true,
            ..
        };
        slot.producer.continuation.state.mode = mode;
        advance(slot);
        assert(slot.producer.render_error);
        assert(!slot.producer.close_required);
    }
}

fn fixed_length_failures() {
    for mode in 2 {
        for committed in[false, true] {
            var slot = silly::StreamSlot<State> {
                fixed_remaining: 2,
                framing: silly::ResponseFraming.Fixed,
                ..
            };
            slot.producer.continuation.state.mode = mode;
            slot.producer.committed = committed;
            advance(slot);
            assert(slot.producer.render_error == !committed);
            assert(slot.producer.close_required == committed);
        }
    }
}

fn bodyless_once() {
    for method in["HEAD", "GET"] {
        var slot = silly::StreamSlot<State> {
            deferred: true,
            retained_cap: 1024,
            ..
        };
        slot.request_method.append(method);
        slot.producer.continuation.state.mode = 2;
        if method == "GET" {
            slot.producer.continuation.metadata.status = 304;
        }
        advance(slot);
        assert(!slot.deferred);
        assert(!slot.producer.render_error);
        assert(slot.producer.continuation.state.calls == 1);
        assert(slot.producer.continuation.state.cancelled == 1);
        advance(slot);
        assert(slot.producer.continuation.state.calls == 1);
        assert(slot.producer.continuation.state.cancelled == 1);
    }
}

fn::main() {
    stream_metadata_test::retention_limits();
    stream_metadata_test::missing_metadata();
    stream_metadata_test::fixed_length_failures();
    stream_metadata_test::bodyless_once();
    print("stream metadata ownership and framing checks passed");
}
