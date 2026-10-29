// Every split preserves validated request metadata, raw fields and unconsumed body bytes.
namespace http_head_test;

import silly from "../../";

import std;

struct ValidHead {
    input: const u8[:],
    method: const u8[:],
    target: const u8[:],
    minor: i32 = 1,
    framing: silly::BodyFraming = silly::BodyFraming.None,
    length: i64 = 0,
}

fn verify_parsed(
    test: ValidHead,
    parsed: silly::ParsedHead,
    fields: silly::HeaderView[:],
    baseline: silly::HeaderView[:]
) {
    assert(parsed.result == silly::HeadResult.Complete);
    assert(parsed.method == test.method);
    assert(parsed.target == test.target);
    assert(parsed.http_minor == test.minor);
    assert(parsed.framing == test.framing);
    assert(parsed.content_length == test.length);
    assert(parsed.head_bytes == find(test.input, "\r\n\r\n") + 4);
    assert(fields.len == baseline.len);
    for index in fields.len {
        assert(fields[index].name == baseline[index].name);
        assert(fields[index].value == baseline[index].value);
    }
}

fn every_split(test: ValidHead) {
    let limits = silly::Limits {
    };
    let head_bytes = find(test.input, "\r\n\r\n") + 4;
    assert(head_bytes >= 4);
    var baseline: silly::HeaderView[>..] = [];
    assert(silly::parse_head(test.input, baseline, limits).result == silly::HeadResult.Complete);
    for split in test.input.len + 1 {
        var scan = silly::HeadScan {
        };
        let first = silly::scan_head(scan, test.input[..split], limits);
        let expected = if split < head_bytes {
            silly::HeadResult.NeedMore
        } else {
            silly::HeadResult.Complete
        };
        assert(first == expected);
        assert(silly::scan_head(scan, test.input, limits) == silly::HeadResult.Complete);
        assert(scan.head_bytes == head_bytes);
        var fields: silly::HeaderView[>..] = [];
        let parsed = silly::parse_head(test.input, fields, limits);
        assert(parsed.head_bytes == scan.head_bytes);
        verify_parsed(test, parsed, fields, baseline);
        assert(test.input[parsed.head_bytes..] == test.input[head_bytes..]);
    }
    var scan = silly::HeadScan {
    };
    for count in test.input.len + 1 {
        let result = silly::scan_head(scan, test.input[..count], limits);
        let expected = if count < head_bytes {
            silly::HeadResult.NeedMore
        } else {
            silly::HeadResult.Complete
        };
        assert(result == expected);
    }
    assert(silly::finish_head(scan) == silly::HeadResult.Complete);
}

fn valid_requests() {
    every_split(ValidHead {
            input: "GET /a?empty=&x=1 HTTP/1.1\r\nHoSt: example.test:8080\r\nX: first \t\r\nx: second\r\n\r\nNEXT",
            method: "GET",
            target: "/a?empty=&x=1",
            ..
        });
    every_split(ValidHead {
            input: "POST /json HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\n\r\n\x00abcGET /next HTTP/1.0\r\n\r\n",
            method: "POST",
            target: "/json",
            framing: silly::BodyFraming.Fixed,
            length: 4,
            ..
        });
    every_split(ValidHead {
            input: "PATCH /empty HTTP/1.1\r\nHost: x\r\nContent-Length: 00, 0\r\nContent-Length: 000\r\n\r\n",
            method: "PATCH",
            target: "/empty",
            framing: silly::BodyFraming.Fixed,
            ..
        });
    every_split(ValidHead {
            input: "POST /upload HTTP/1.1\r\nHost: [::1]:443\r\nTransfer-Encoding: ChUnKeD\r\n\r\n0\r\n\r\n",
            method: "POST",
            target: "/upload",
            framing: silly::BodyFraming.Chunked,
            ..
        });
    every_split(ValidHead {
            input: "CUSTOM-TOKEN /raw%2Fid HTTP/1.0\r\nX: \x80\r\n\r\n",
            method: "CUSTOM-TOKEN",
            target: "/raw%2Fid",
            minor: 0,
            ..
        });
    every_split(ValidHead {
            input: "OPTIONS * HTTP/1.1\r\nHost: x\r\n\r\n",
            method: "OPTIONS",
            target: "*",
            ..
        });
    every_split(ValidHead {
            input: "CONNECT example.test:443 HTTP/1.1\r\nHost: example.test:443\r\n\r\n",
            method: "CONNECT",
            target: "example.test:443",
            ..
        });
    every_split(ValidHead {
            input: "GET https://example.test/a?b=c HTTP/1.1\r\nHost: example.test\r\n\r\n",
            method: "GET",
            target: "https://example.test/a?b=c",
            ..
        });
}

fn raw_headers() {
    let input = "GET / HTTP/1.1\r\nHoSt: x\r\nX-Dup: \tfirst \t\r\nx-dup:\tsecond\r\nX-Empty:\r\n\r\n";
    var fields: silly::HeaderView[>..] = [];
    assert(silly::parse_head(input, fields, silly::Limits {
        }).result == silly::HeadResult.Complete);
    assert(fields.len == 4);
    assert(fields[0].name == "HoSt");
    assert(fields[1].value == " \tfirst \t");
    assert(fields[2].value == "\tsecond");
    assert(fields[3].value == "");
    let request = silly::Request {
        method: "GET",
        target: "/",
        headers: fields,
        ..
    };
    assert(silly::header(request, "X-DUP").value == "first");
    assert(silly::header_raw(request, "x-dup").value == "first \t");
    assert(silly::header(request, "x-empty").present);
    assert(!silly::header(request, "missing").present);
    assert(silly::find_header(fields, "X-Dup") == 1);
    assert(silly::find_header(fields, "X-Dup", 2) == 2);
}

fn fixed_lengths() {
    every_split(ValidHead {
            input: "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 01, 1\r\nContent-Length: 001\r\n\r\nx",
            method: "POST",
            target: "/",
            framing: silly::BodyFraming.Fixed,
            length: 1,
            ..
        });
    every_split(ValidHead {
            input: "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 9223372036854775807\r\n\r\n",
            method: "POST",
            target: "/",
            framing: silly::BodyFraming.Fixed,
            length: 9223372036854775807,
            ..
        });
}

fn::main() {
    http_head_test::valid_requests();
    http_head_test::raw_headers();
    http_head_test::fixed_lengths();
    print("http head split and fidelity contracts passed");
}
