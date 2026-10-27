// Bounded pull decoding: output chunks are consumed before the next read.
namespace body_reader_example;

import silly from "..";

import std;

fn::main() {
    let wire = "3\r\na\x00b\r\n0\r\nX-Checksum: ok\r\n\r\nnext request";
    let expected = "a\x00b";
    var reader = silly::new_body_reader(silly::BodyFraming.Chunked, 0, silly::BodyLimits {
            bytes_max: 64,
            ..
        });
    var output: u8[2] = [0; 2];
    var consumed: i64 = 0;
    var delivered: i64 = 0;
    while reader.status != silly::BodyStatus.Complete {
        let result = silly::read_body(reader, wire[consumed..], output, 16);
        consumed += result.consumed;
        assert(output[..result.produced] == expected[delivered..delivered + result.produced]);
        delivered += result.produced;
        assert(result.status == silly::BodyStatus.Progress || result.status == silly::BodyStatus.NeedOutput
            || result.status == silly::BodyStatus.Complete);
    }
    assert(delivered == 3);
    assert(wire[consumed..] == "next request");
    print("bounded binary body decoding passed");
}
