// Indexed lookup preserves raw bytes, presence, spelling and repeated wire order.
namespace indexed_headers;

import silly from "..";

import std;

import.indexed_header_fixture;

fn values(request: silly::Request) {
    indexed_header_test::value(silly::header(request, "x-MiXeD"), "first");
    indexed_header_test::value(silly::header_raw(request, "X-MIXED"), "first \t");
    indexed_header_test::value(silly::header_wire(request, "x-mixed"), " \tfirst \t");
    assert(!silly::header(request, "Missing").present);
    assert(!silly::header_raw(request, "Missing").present);
    assert(!silly::header_wire(request, "Missing").present);
    indexed_header_test::value(silly::header_wire(request, "X-Empty"), "");
    indexed_header_test::value(silly::header_wire(request, "X-Space"), " \t ");
    indexed_header_test::value(silly::header(request, "X-Space"), "");
    indexed_header_test::value(silly::header_raw(request, "X-Space"), "");
    var trimmed = silly::header_values(request, "X-MIXED");
    indexed_header_test::value(silly::next_header(trimmed), "first");
    indexed_header_test::value(silly::next_header(trimmed), "");
    indexed_header_test::value(silly::next_header(trimmed), "third, fourth");
    assert(!silly::next_header(trimmed).present);
    assert(!silly::next_header(trimmed).present);
    var raw = silly::header_values(request, "x-mixed", silly::HeaderValueMode.Raw);
    indexed_header_test::value(silly::next_header(raw), "first \t");
    indexed_header_test::value(silly::next_header(raw), "");
    indexed_header_test::value(silly::next_header(raw), "third, fourth \t");
    assert(!silly::next_header(raw).present);
    var wire = silly::header_values(request, "X-Mixed", silly::HeaderValueMode.Wire);
    indexed_header_test::value(silly::next_header(wire), " \tfirst \t");
    indexed_header_test::value(silly::next_header(wire), "");
    indexed_header_test::value(silly::next_header(wire), " third, fourth \t");
    assert(!silly::next_header(wire).present);
    var absent = silly::header_values(request, "missing");
    assert(!silly::next_header(absent).present);
}

fn wire_fidelity() {
    var wire: u8[>..] = [];
    wire.append("GET / HTTP/1.1\r\nHost: example\r\nX-Mixed: \tfirst \t\r\nX-Empty:\r\n");
    wire.append("x-mixed:\r\nX-Space: \t \r\nX-MIXED: third, fourth \t\r\n\r\nbody");
    var fields: silly::HeaderView[>..] = [];
    var index: silly::HeaderIndexEntry[>..] = [];
    let parsed = silly::parse_head(wire, fields, index, silly::Limits {
        });
    assert(parsed.result == silly::HeadResult.Complete);
    assert(index.len == 6);
    assert(fields.len == 6);
    assert(wire[parsed.head_bytes..] == "body");
    assert(fields[1].name == "X-Mixed");
    assert(fields[3].name == "x-mixed");
    assert(fields[5].name == "X-MIXED");
    for item in index {
        let field = fields[item.field_index];
        let source = item.source;
        assert(wire[source.name_start..source.name_start + source.name_bytes] == field.name);
        assert(wire[source.value_start..source.value_start + source.value_bytes] == field.value);
    }
    let request = silly::Request {
        method: parsed.method,
        target: parsed.target,
        headers: fields,
        header_index: index,
        ..
    };
    values(request);
    assert(fields[1].value == " \tfirst \t");
}

fn unindexed() {
    let fields = [
        silly::HeaderView {
            name: "X",
            value: " a "
        },
        silly::HeaderView {
            name: "x",
            value: ""
        },
        silly::HeaderView {
            name: "X",
            value: "\tb\t"
        },
    ];
    let request = silly::Request {
        method: "GET",
        target: "/",
        headers: fields,
        ..
    };
    indexed_header_test::value(silly::header(request, "x"), "a");
    indexed_header_test::value(silly::header_raw(request, "x"), "a ");
    indexed_header_test::value(silly::header_wire(request, "x"), " a ");
    var values = silly::header_values(request, "x");
    indexed_header_test::value(silly::next_header(values), "a");
    indexed_header_test::value(silly::next_header(values), "");
    indexed_header_test::value(silly::next_header(values), "b");
    assert(!silly::next_header(values).present);
}

fn failures() {
    let limits = silly::Limits {
        header_count_max: 2,
        ..
    };
    var fields: silly::HeaderView[>..] = [];
    var index: silly::HeaderIndexEntry[>..] = [];
    let over = "GET / HTTP/1.1\r\nHost: x\r\nX: 1\r\nX: 2\r\n\r\n";
    let result = silly::parse_head(over, fields, index, limits);
    assert(result.result == silly::HeadResult.HeaderLimit);
    assert(index.len == 0);
    assert(fields.len == 0);
    let duplicate = "GET / HTTP/1.1\r\nHost: x\r\nAuthorization: a\r\nauthorization: b\r\n\r\n";
    let rejected = silly::parse_head(duplicate, fields, index, silly::Limits {
        });
    assert(rejected.result == silly::HeadResult.BadRequest);
    assert(index.len == 0);
    assert(fields.len == 0);
    let incomplete = silly::parse_head("GET / HTTP/1.1\r\nHost:", fields, index, limits);
    assert(incomplete.result == silly::HeadResult.NeedMore);
    assert(index.len == 0);
    assert(fields.len == 0);
    let exact = silly::parse_head("GET / HTTP/1.1\r\nHost: x\r\nX:\r\n\r\n", fields, index, limits);
    assert(exact.result == silly::HeadResult.Complete);
    assert(index.len == 2);
}

fn read_before_reset(bytes: u8[:], expected: u8[:]) {
    var fields: silly::HeaderView[>..] = [];
    var index: silly::HeaderIndexEntry[>..] = [];
    let parsed = silly::parse_head(bytes, fields, index, silly::Limits {
        });
    assert(parsed.result == silly::HeadResult.Complete);
    let request = silly::Request {
        method: parsed.method,
        target: parsed.target,
        headers: fields,
        header_index: index,
        ..
    };
    var values = silly::header_values(request, "x");
    indexed_header_test::value(silly::next_header(values), expected);
    assert(!silly::next_header(values).present);
}

fn reset_after_use() {
    var bytes: u8[>..] = [];
    for iteration in 2 {
        let expected = if iteration == 0 {
            "old"
        } else {
            "new"
        };
        bytes.append("GET / HTTP/1.1\r\nHost: x\r\nX: ");
        bytes.append(expected);
        bytes.append("\r\n\r\n");
        read_before_reset(bytes, expected);
        bytes.clear();
    }
}

fn::main() {
    indexed_headers::wire_fidelity();
    indexed_headers::unindexed();
    indexed_headers::failures();
    indexed_headers::reset_after_use();
    print("indexed header contracts passed");
}
