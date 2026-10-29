// Driver-owned input and metadata retained for one request-access callback.
namespace indexed_header_test;

import silly from "../../";

import std;

fn with_request<F>(wire: u8[:]) {
    var fields: silly::HeaderView[>..] = [];
    var index: silly::HeaderIndexEntry[>..] = [];
    let parsed = silly::parse_head(wire, fields, index, silly::Limits {
        });
    assert(parsed.result == silly::HeadResult.Complete);
    let request = silly::Request {
        method: parsed.method,
        target: parsed.target,
        headers: fields,
        header_index: index,
        ..
    };
    F(request);
}

fn value(field: silly::FieldValue, expected: u8[:]) {
    assert(field.present);
    assert(field.value == expected);
}
