// Every split, binary payloads, exact terminal boundaries and bounded collection.
namespace http_body_test;

import silly from "../../";

import std;

import.http_body_fixture;

fn valid_chunks() {
    let wire = "3;name=value;quoted=\"a;\\\"b\"\r\na\x00b\r\n2 \t; flag \t= \tword\r\n\xffz\r\n000;end\r\nX-Trailer: kept\r\nx-trailer:\r\n\r\nNEXT";
    body_test::splits(body_test::Case {
            framing: silly::BodyFraming.Chunked,
            wire: wire,
            expected: "a\x00b\xffz",
            consumed: wire.len - 4,
            ..
        });
    body_test::splits(body_test::Case {
            framing: silly::BodyFraming.Chunked,
            wire: "0\r\n\r\nNEXT",
            expected: "",
            consumed: 5,
            ..
        });
    body_test::splits(body_test::Case {
            framing: silly::BodyFraming.Chunked,
            wire: "0A\r\n0123456789\r\n0\r\n\r\nNEXT",
            expected: "0123456789",
            consumed: 21,
            ..
        });
    body_test::splits(body_test::Case {
            framing: silly::BodyFraming.Fixed,
            length: 8,
            wire: "{\"x\":0}\nNEXT",
            expected: "{\"x\":0}\n",
            consumed: 8,
        });
}

fn absent_empty_and_eof() {
    var absent = silly::new_body_reader(silly::BodyFraming.None, 0, silly::BodyLimits {
        });
    var empty = silly::new_body_reader(silly::BodyFraming.Fixed, 0, silly::BodyLimits {
        });
    assert(absent.framing == silly::BodyFraming.None);
    assert(empty.framing == silly::BodyFraming.Fixed);
    assert(silly::finish_body(absent) == silly::BodyStatus.Complete);
    assert(silly::finish_body(empty) == silly::BodyStatus.Complete);
    var missing = silly::new_body_reader(silly::BodyFraming.Fixed, 1, silly::BodyLimits {
        });
    var scratch: u8[1] = [0];
    assert(silly::read_body(missing, "", scratch, 1).status == silly::BodyStatus.NeedInput);
    assert(silly::finish_body(missing) == silly::BodyStatus.Truncated);
    assert(silly::read_body(missing, "x", scratch, 1).status == silly::BodyStatus.Truncated);
    var chunked = silly::new_body_reader(silly::BodyFraming.Chunked, 0, silly::BodyLimits {
        });
    assert(silly::finish_body(chunked) == silly::BodyStatus.Truncated);
}

fn read_large(framing: silly::BodyFraming, wire: u8[:], expected: u8[:]) {
    let length = if framing == silly::BodyFraming.Fixed {
        expected.len
    } else {
        0
    };
    var reader = silly::new_body_reader(framing, length, silly::BodyLimits {
            bytes_max: expected.len,
            ..
        });
    var output: u8[>..] = [];
    var cursor: i64 = 0;
    while reader.status != silly::BodyStatus.Complete {
        let result = silly::collect_body(reader, wire[cursor..], output, expected.len, 8192);
        assert(result.consumed <= 8192);
        assert(result.consumed > 0);
        assert(output.len <= expected.len);
        cursor += result.consumed;
        assert(result.status == silly::BodyStatus.Progress || result.status == silly::BodyStatus.NeedInput
            || result.status == silly::BodyStatus.NeedOutput || result.status == silly::BodyStatus.Complete);
    }
    assert(wire[cursor..] == "NEXT");
    assert(output == expected);
    let complete = silly::collect_body(reader, "NEXT", output, expected.len, 8192);
    assert(complete.status == silly::BodyStatus.Complete);
    assert(complete.consumed == 0);
    assert(complete.produced == 0);
}

fn stream_large(framing: silly::BodyFraming, wire: u8[:], expected: u8[:]) {
    let length = if framing == silly::BodyFraming.Fixed {
        expected.len
    } else {
        0
    };
    var reader = silly::new_body_reader(framing, length, silly::BodyLimits {
            bytes_max: expected.len,
            ..
        });
    var scratch: u8[4096] = [0; 4096];
    var consumed: i64 = 0;
    var produced: i64 = 0;
    while reader.status != silly::BodyStatus.Complete {
        let result = silly::read_body(reader, wire[consumed..], scratch, 4096);
        assert(result.consumed > 0);
        assert(result.consumed <= 4096);
        assert(result.produced <= scratch.len);
        assert(scratch[..result.produced] == expected[produced..produced + result.produced]);
        consumed += result.consumed;
        produced += result.produced;
    }
    assert(produced == expected.len);
    assert(wire[consumed..] == "NEXT");
}

fn large_binary() {
    var payload: u8[>..] = [];
    for index in 262145 {
        payload.push((index % 251)as u8);
    }
    var fixed: u8[>..] = [];
    fixed.append(payload);
    fixed.append("NEXT");
    read_large(silly::BodyFraming.Fixed, fixed, payload);
    stream_large(silly::BodyFraming.Fixed, fixed, payload);
    var chunked: u8[>..] = [];
    chunked.append("40001;large=yes\r\n");
    chunked.append(payload);
    chunked.append("\r\n0\r\nX-Final: ok\r\n\r\nNEXT");
    read_large(silly::BodyFraming.Chunked, chunked, payload);
    stream_large(silly::BodyFraming.Chunked, chunked, payload);
}

fn::main() {
    http_body_test::valid_chunks();
    http_body_test::absent_empty_and_eof();
    http_body_test::large_binary();
    print("incremental body and collection contracts passed");
}
