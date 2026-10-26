// Rejected heads stay rejected across fragmentation and poison trailing bytes.
namespace http_head_invalid_test;

import silly from "..";

import std;

fn rejected(input: u8[:], expected: silly::HeadResult) {
    let limits = silly::Limits {
    };
    for split in input.len + 1 {
        var scan = silly::HeadScan {
        };
        silly::scan_head(scan, input[..split], limits);
        let scanned = silly::scan_head(scan, input, limits);
        var fields: silly::HeaderView[>..] = [];
        let parsed = silly::parse_head(input, fields, limits);
        assert(parsed.result == expected);
        if scanned != silly::HeadResult.NeedMore && scanned != silly::HeadResult.Complete {
            assert(silly::scan_head(scan, input, limits) == scanned);
            assert(silly::finish_head(scan) == scanned);
        }
    }
}

fn bad_syntax() {
    let inputs = [
        "GET / HTTP/1.1\nHost: x\n\n",
        "GET / HTTP/1.1\rHost: x\r\n\r\n",
        "GET\t/ HTTP/1.1\r\nHost: x\r\n\r\n",
        "GE(T / HTTP/1.1\r\nHost: x\r\n\r\n",
        " GET / HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET  / HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET / HTTP/1.1 extra\r\nHost: x\r\n\r\n",
        "GET /#fragment HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET /bad\x00path HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET /bad\tpath HTTP/1.1\r\nHost: x\r\n\r\n",
        "GET / HTTP/1.1\r\nBad Name: value\r\nHost: x\r\n\r\n",
        "GET / HTTP/1.1\r\nX : value\r\nHost: x\r\n\r\n",
        "GET / HTTP/1.1\r\n: value\r\nHost: x\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x\r\n folded\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x\r\nX: bad\x7fvalue\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x\r\nX: bad\x01value\r\n\r\n",
        "GET * HTTP/1.1\r\nHost: x\r\n\r\n",
        "CONNECT /path HTTP/1.1\r\nHost: x\r\n\r\n",
    ];
    for input in inputs {
        rejected(input, silly::HeadResult.BadRequest);
    }
    rejected("GET / HTTP/2.0\r\nHost: x\r\n\r\n", silly::HeadResult.UnsupportedVersion);
}

fn bad_hosts_and_singletons() {
    let inputs = [
        "GET / HTTP/1.1\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: \t\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x\r\nhost: x\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x,y\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: user@x\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x/path\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x:65536\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x:\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x:-1\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: [::1\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: [bad::gg]\r\n\r\n",
        "GET / HTTP/1.1\r\nHost: x\r\nAuthorization: a\r\nauthorization: a\r\n\r\n",
        "POST / HTTP/1.1\r\nHost: x\r\nContent-Type: a\r\ncontent-type: a\r\n\r\n",
    ];
    for input in inputs {
        rejected(input, silly::HeadResult.BadRequest);
    }
}

fn bad_lengths() {
    let values = ["", " ", "+1", "-0", "1x", "1 1", "1,", ",1", "1,,1", "1,2", "9223372036854775808"];
    for value in values {
        let input = str("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: ", value, "\r\n\r\n");
        rejected(input, silly::HeadResult.BadRequest);
    }
    rejected("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n",
        silly::HeadResult.BadRequest);
}

fn bad_transfer_encoding() {
    let values = ["", "chunked,", ",chunked", "chunked,,chunked", "chunked, chunked", "chunked, gzip",
        "chunked;foo=bar", "chun ked"];
    for value in values {
        let input = str("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: ", value, "\r\n\r\n");
        rejected(input, silly::HeadResult.BadRequest);
    }
    rejected("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip\r\n\r\n",
        silly::HeadResult.BadRequest);
    rejected("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: gzip, chunked\r\n\r\n",
        silly::HeadResult.UnsupportedTransferCoding);
    rejected("POST / HTTP/1.0\r\nTransfer-Encoding: chunked\r\n\r\n", silly::HeadResult.BadRequest);
    rejected("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n",
        silly::HeadResult.BadRequest);
    rejected("POST / HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: chunked\r\n\r\n",
        silly::HeadResult.BadRequest);
}

fn poison_and_truncation() {
    let extra = "GET /innocent HTTP/1.1\r\nHost: x\r\n\r\n";
    let ambiguous = str("POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 1,2\r\n\r\nx", extra);
    rejected(ambiguous, silly::HeadResult.BadRequest);
    let malformed = str("GET / HTTP/1.1\n", extra);
    rejected(malformed, silly::HeadResult.BadRequest);
    for length in extra.len {
        var scan = silly::HeadScan {
        };
        assert(silly::scan_head(scan, extra[..length], silly::Limits {
            }) == silly::HeadResult.NeedMore);
        assert(silly::finish_head(scan) == silly::HeadResult.Truncated);
        assert(silly::scan_head(scan, extra, silly::Limits {
            }) == silly::HeadResult.Truncated);
    }
}

fn::main() {
    http_head_invalid_test::bad_syntax();
    http_head_invalid_test::bad_hosts_and_singletons();
    http_head_invalid_test::bad_lengths();
    http_head_invalid_test::bad_transfer_encoding();
    http_head_invalid_test::poison_and_truncation();
    print("http head rejection contracts passed");
}
