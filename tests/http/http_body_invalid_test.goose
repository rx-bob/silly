// Framing errors and EOF are explicit terminal states, never repaired by trailing bytes.
namespace http_body_invalid_test;

import silly from "../../";

import std;

import.http_body_fixture;

fn malformed() {
    let inputs = [
        "-1\r\n", "+1\r\n", "g\r\n", "\r\n", " 1\r\n", "1\n", "1\rx",
        "8000000000000000\r\n", "ffffffffffffffffffffffff\r\n",
        "1;=x\r\n", "1;foo=\r\n", "1;foo=\"unterminated\r\n",
        "1;foo=\"x\"junk\r\n", "1;foo=\"x\x00\"\r\n",
        "1\r\naX", "1\r\na\rX", "0\r\n folded: no\r\n\r\n",
        "0\r\nBad Name: no\r\n\r\n", "0\r\nX: a\x00b\r\n\r\n",
        "0\r\nContent-Length: 0\r\n\r\n", "0\r\nTransfer-Encoding: chunked\r\n\r\n",
        "0\r\nHost: other\r\n\r\n", "0\r\nAuthorization: forged\r\n\r\n",
    ];
    for input in inputs {
        body_test::failure(input, silly::BodyStatus.BadFraming, silly::BodyLimits {
            });
    }
}

fn missing_terminators() {
    let valid = "3;foo=\"bar\"\r\nabc\r\n0\r\nX: value\r\n\r\n";
    for end in valid.len {
        var reader = silly::new_body_reader(silly::BodyFraming.Chunked, 0, silly::BodyLimits {
            });
        var scratch: u8[8] = [0; 8];
        let partial = silly::read_body(reader, valid[..end], scratch, 1000);
        assert(partial.status == silly::BodyStatus.NeedInput);
        assert(silly::finish_body(reader) == silly::BodyStatus.Truncated);
        let later = silly::read_body(reader, valid[end..], scratch, 1000);
        assert(later.status == silly::BodyStatus.Truncated);
        assert(later.consumed == 0);
        assert(later.produced == 0);
    }
    var fixed = silly::new_body_reader(silly::BodyFraming.Fixed, 4, silly::BodyLimits {
        });
    var scratch: u8[8] = [0; 8];
    let result = silly::read_body(fixed, "abc", scratch, 1000);
    assert(result.produced == 3);
    assert(result.status == silly::BodyStatus.NeedInput);
    assert(silly::finish_body(fixed) == silly::BodyStatus.Truncated);
}

fn::main() {
    http_body_invalid_test::malformed();
    http_body_invalid_test::missing_terminators();
    print("body framing failure contracts passed");
}
