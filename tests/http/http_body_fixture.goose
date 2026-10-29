// Shared pull-reader checks use bounded destinations and preserve unconsumed tails.
namespace body_test;

import silly from "../../";

import std;

struct Case {
    framing: silly::BodyFraming,
    length: i64 = 0,
    wire: const u8[:],
    expected: const u8[:],
    consumed: i64,
}

fn pump(reader: silly::BodyReader&, input: u8[:], output: u8[>..]&) -> i64 {
    var cursor: i64 = 0;
    var scratch: u8[7] = [0; 7];
    while cursor < input.len {
        let result = silly::read_body(reader, input[cursor..], scratch, 3);
        assert(result.consumed >= 0);
        assert(result.consumed <= 3);
        assert(result.produced <= scratch.len);
        output.append(scratch[..result.produced]);
        cursor += result.consumed;
        if result.status == silly::BodyStatus.Complete {
            break;
        }
        assert(result.status == silly::BodyStatus.Progress || result.status == silly::BodyStatus.NeedInput
            || result.status == silly::BodyStatus.NeedOutput);
        assert(result.consumed > 0 || result.produced > 0);
    }
    return cursor;
}

fn splits(test: Case) {
    for split in test.wire.len + 1 {
        var reader = silly::new_body_reader(test.framing, test.length, silly::BodyLimits {
            });
        var output: u8[>..] = [];
        let first = pump(reader, test.wire[..split], output);
        let second = pump(reader, test.wire[split..], output);
        assert(first + second == test.consumed);
        assert(output == test.expected);
        assert(silly::finish_body(reader) == silly::BodyStatus.Complete);
    }
    var reader = silly::new_body_reader(test.framing, test.length, silly::BodyLimits {
        });
    var output: u8[>..] = [];
    var consumed: i64 = 0;
    for index in test.wire.len {
        consumed += pump(reader, test.wire[index..index + 1], output);
    }
    assert(consumed == test.consumed);
    assert(output == test.expected);
    assert(silly::finish_body(reader) == silly::BodyStatus.Complete);
}

fn failure(wire: u8[:], expected: silly::BodyStatus, limits: silly::BodyLimits) {
    var reader = silly::new_body_reader(silly::BodyFraming.Chunked, 0, limits);
    var scratch: u8[64] = [0; 64];
    let result = silly::read_body(reader, wire, scratch, 100000);
    assert(result.status == expected);
    let again = silly::read_body(reader, "0\r\n\r\nNEXT", scratch, 100000);
    assert(again.status == expected);
    assert(again.consumed == 0);
    assert(again.produced == 0);
    assert(silly::finish_body(reader) == expected);
}
