namespace http_date_test;

import http_date from "../src";

import std;

fn::main() {
    let now = 1793064000;
    for value in["Sun, 06 Nov 1994 08:49:37 GMT", "Sunday, 06-Nov-94 08:49:37 GMT", "Sun Nov  6 08:49:37 1994"] {
        let parsed = silly::parse_http_date(value, now);
        assert(parsed.valid);
        assert(parsed.seconds == 784111777);
        assert(silly::format_http_date(parsed.seconds) == "Sun, 06 Nov 1994 08:49:37 GMT");
    }
    for seconds in[0, 951782400, 4107542400, 253402300799] {
        let formatted = silly::format_http_date(seconds);
        let parsed = silly::parse_http_date(formatted, now);
        assert(parsed.valid);
        assert(parsed.seconds == seconds);
    }
    for value in["", "Sun, 31 Feb 2026 08:49:37 GMT", "Sun, 06 Nov 1994 24:49:37 GMT",
        "Sun, 06 Nov 1994 08:60:37 GMT", "Sun, 06 Nov 1994 08:49:61 GMT",
        "Sun, 06 Nov 1994 08:49:37 UTC", "Sun, 06 Nov 1994 08:49:37 GMTx",
        "Sun, 29 Feb 2100 08:49:37 GMT", "Sun, 06 Xxx 1994 08:49:37 GMT"] {
        assert(!silly::parse_http_date(value, now).valid);
    }
    assert(silly::format_http_date(-1).len == 0);
    assert(silly::format_http_date(253402300800).len == 0);
    let threshold = silly::parse_http_date("Mon, 26 Oct 2026 12:00:00 GMT", now).seconds;
    let future = silly::parse_http_date("Monday, 26-Oct-76 12:00:00 GMT", threshold);
    let past = silly::parse_http_date("Monday, 26-Oct-76 12:00:01 GMT", threshold);
    assert(future.valid);
    assert(silly::format_http_date(future.seconds) == "Mon, 26 Oct 2076 12:00:00 GMT");
    assert(past.valid);
    assert(silly::format_http_date(past.seconds) == "Tue, 26 Oct 1976 12:00:01 GMT");
    let old_now = silly::parse_http_date("Sun, 06 Nov 1994 08:49:37 GMT", now).seconds;
    let next_century = silly::parse_http_date("Sunday, 06-Nov-20 08:49:37 GMT", old_now);
    assert(next_century.valid);
    assert(silly::format_http_date(next_century.seconds) == "Fri, 06 Nov 2020 08:49:37 GMT");
    print("HTTP date parsing and formatting passed");
}
