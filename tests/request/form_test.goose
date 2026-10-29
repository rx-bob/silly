// Strict form decoding preserves repeated/empty values and never mutates scratch on failure.
namespace form_test;

import silly from "../../";

import std;

fn request(body: u8[:], fields: silly::HeaderView[:]) -> silly::Request {
    return silly::Request {
        method: "POST",
        target: "/submit",
        headers: fields,
        body_state: silly::RequestBody.Buffered {
            bytes: body
        },
        ..
    };
}

fn fields() {
    let headers = [silly::HeaderView {
            name: "Content-Type",
            value: "Application/X-WWW-Form-Urlencoded; charset=\"UTF-8\""
        }];
    var scratch: u8[>..] = [];
    let form = silly::parse_form(request("name=Ada+Lovelace&name=Grace&flag&empty=&=v&&", headers), scratch);
    assert(form.error == silly::FormError.None);
    assert(form.pairs.count == 7);
    assert(form.get("name").value == "Ada Lovelace");
    assert(form.get("flag").present);
    assert(form.get("flag").value == "");
    var pairs = silly::query_iterator(form.pairs);
    assert(silly::next_query_pair(pairs).present);
    assert(silly::next_query_pair(pairs).present);
    assert(!silly::next_query_pair(pairs).pair.has_equals);
    assert(silly::next_query_pair(pairs).pair.has_equals);
    assert(form.get("empty").present);
    assert(!form.get("absent").present);
    assert(form.get("").value == "v");
    var names = silly::form_values(form, "name");
    assert(silly::next_query_value(names).value == "Ada Lovelace");
    assert(silly::next_query_value(names).value == "Grace");
    assert(!silly::next_query_value(names).present);
}

fn bytes() {
    let headers = [silly::HeaderView {
            name: "Content-Type",
            value: "application/x-www-form-urlencoded"
        }];
    var scratch: u8[>..] = [];
    let body = "key=a%26b%3Dc&plus=%2B+&id=%252F&email=a%2Bb%40x.test&nul=%00&utf=%C3%A9&raw=%FF";
    let form = silly::parse_form(request(body, headers), scratch);
    assert(form.error == silly::FormError.None);
    assert(form.get("key").value == "a&b=c");
    assert(form.get("plus").value == "+ ");
    assert(form.get("id").value == "%2F");
    assert(form.get("email").value == "a+b@x.test");
    assert(form.get("nul").value == "\x00");
    assert(form.get("utf").value == "\xc3\xa9");
    assert(form.get("raw").value == "\xff");
}

fn failure(body: u8[:], content_type: u8[:], options: silly::FormOptions, expected: silly::FormError) {
    let headers = [silly::HeaderView {
            name: "Content-Type",
            value: content_type
        }];
    var scratch: u8[>..] = [];
    scratch.append("unchanged");
    let form = silly::parse_form(request(body, headers), scratch, options);
    assert(form.error == expected);
    assert(scratch == "unchanged");
    assert(!form.get("a").present);
}

fn media() {
    for accepted in["application/x-www-form-urlencoded", " APPLICATION/X-WWW-FORM-URLENCODED\t",
        "application/x-www-form-urlencoded ; charset = utf-8", "application/x-www-form-urlencoded;CHARSET=\"UTF-8\""] {
        assert(silly::form_media_type(accepted));
    }
    for rejected in["", "text/plain", "application/x-www-form-urlencodedx",
        "application/x-www-form-urlencoded;", "application/x-www-form-urlencoded;charset=latin1",
        "application/x-www-form-urlencoded;charset=utf-8;charset=utf-8",
        "application/x-www-form-urlencoded; boundary=foo", "application/x-www-form-urlencoded;charset=\"utf-8",
        "application/x-www-form-urlencoded;charset=\"utf-8\"junk"] {
        failure("a=b", rejected, silly::FormOptions {
            }, silly::FormError.UnsupportedMediaType);
    }
    let duplicate = [silly::HeaderView {
            name: "Content-Type",
            value: "application/x-www-form-urlencoded"
        },
        silly::HeaderView {
            name: "content-type",
            value: "application/x-www-form-urlencoded"
        }];
    var scratch: u8[>..] = [];
    let duplicated = silly::parse_form(request("a=b", duplicate), scratch);
    assert(duplicated.error == silly::FormError.UnsupportedMediaType);
    let empty: silly::HeaderView[0] = [];
    let missing = silly::parse_form(request("", empty), scratch);
    assert(missing.error == silly::FormError.UnsupportedMediaType);
}

fn limits() {
    let content_type = "application/x-www-form-urlencoded";
    failure("a=%", content_type, silly::FormOptions {
        }, silly::FormError.InvalidEncoding);
    failure("a=%GG", content_type, silly::FormOptions {
        }, silly::FormError.InvalidEncoding);
    failure("a=ok&b=%2", content_type, silly::FormOptions {
        }, silly::FormError.InvalidEncoding);
    failure("a=b&c=d", content_type, silly::FormOptions {
            pairs_max: 1,
            ..
        }, silly::FormError.PairLimit);
    failure("a=%41", content_type, silly::FormOptions {
            decoded_bytes_max: 1,
            ..
        }, silly::FormError.DecodedLimit);
    failure("a=b", content_type, silly::FormOptions {
            input_bytes_max: 2,
            ..
        }, silly::FormError.InputLimit);
    failure("", content_type, silly::FormOptions {
            pairs_max: -1,
            ..
        }, silly::FormError.InvalidOptions);
    let headers = [silly::HeaderView {
            name: "Content-Type",
            value: content_type
        }];
    var scratch: u8[>..] = [];
    let exact = silly::parse_form(request("a=%41", headers), scratch,
        silly::FormOptions {
            input_bytes_max: 5,
            decoded_bytes_max: 2,
            pairs_max: 1
        });
    assert(exact.error == silly::FormError.None);
    assert(exact.get("a").value == "A");
}

fn empty_and_unavailable() {
    let headers = [silly::HeaderView {
            name: "Content-Type",
            value: "application/x-www-form-urlencoded"
        }];
    var scratch: u8[>..] = [];
    let empty = silly::parse_form(request("", headers), scratch,
        silly::FormOptions {
            input_bytes_max: 0,
            pairs_max: 0,
            decoded_bytes_max: 0
        });
    assert(empty.error == silly::FormError.None);
    assert(empty.pairs.count == 0);
    let streamed = silly::Request {
        method: "POST",
        target: "/",
        headers: headers,
        body_state: silly::RequestBody.Streamed,
        ..
    };
    let unavailable = silly::parse_form(streamed, scratch);
    assert(unavailable.error == silly::FormError.BodyUnavailable);
    assert(scratch.len == 0);
}

fn::main() {
    form_test::fields();
    form_test::bytes();
    form_test::media();
    form_test::limits();
    form_test::empty_and_unavailable();
    print("strict bounded form decoding passed");
}
