// Borrowed JSON value views preserve types, lookup policy and missing/null distinctions.
namespace json_view_test;

import silly from "../../";

fn::main() {
    json_view_test::invalid_and_limits();
    json_view_test::unicode_and_duplicates();
    json_view_test::maximum_depth();
    json_view_test::raw_strings();
    var scratch: u8[>..] = [];
    let doc = silly::parse_json("{\"a\": [null, \"h\\u0069\"], \"\\u0062\":true}", scratch);
    assert(doc.error == silly::JsonError.None);
    assert(scratch == "hib");
    let a = silly::json_member(doc.value, "a");
    assert(a.present);
    var elements = silly::json_array(a.value);
    assert(silly::next_json_element(elements).value.kind == silly::JsonKind.Null);
    assert(silly::json_string(silly::next_json_element(elements).value).value == "hi");
    assert(!silly::next_json_element(elements).present);
    assert(silly::json_member(doc.value, "b").value.raw == "true");
    assert(!silly::json_member(doc.value, "missing").present);
}

fn invalid_and_limits() {
    let invalid = ["", " ", "01", "-", "1.", "1e", "true false", "[1,]", "{\"x\":}",
        "{x:1}", "\"\\x\"", "\"\\uD800\"", "\"\\uDC00\"", "\"\\uD800\\u0041\"", "\"\n\""];
    for text in invalid {
        var scratch: u8[>..] = ['x'];
        assert(silly::parse_json(text, scratch).error != silly::JsonError.None);
        assert(scratch == "x");
    }
    var scratch: u8[>..] = ['x'];
    let bad_utf8: u8[4] = ['"', 0xC0, 0x80, '"'];
    assert(silly::parse_json(bad_utf8, scratch).error == silly::JsonError.InvalidString);
    assert(silly::parse_json("[0]", scratch, silly::JsonLimits {
            body_bytes_max: 2,
            ..
        }).error == silly::JsonError.BodyLimit);
    assert(silly::parse_json("[0]", scratch, silly::JsonLimits {
            collection_max: 0,
            ..
        }).error == silly::JsonError.CollectionLimit);
    assert(silly::parse_json("[[]]", scratch, silly::JsonLimits {
            depth_max: 1,
            ..
        }).error == silly::JsonError.DepthLimit);
    assert(silly::parse_json("\"\\u0061\"", scratch, silly::JsonLimits {
            decoded_bytes_max: 1,
            ..
        }).error == silly::JsonError.ScratchLimit);
    assert(silly::parse_json("\"ab\"", scratch, silly::JsonLimits {
            decoded_bytes_max: 1,
            ..
        }).error == silly::JsonError.ScratchLimit);
    assert(silly::parse_json("0", scratch, silly::JsonLimits {
            depth_max: 257,
            ..
        }).error == silly::JsonError.InvalidOptions);
    assert(scratch == "x");
}

fn unicode_and_duplicates() {
    var scratch: u8[>..] = ['x'];
    let doc = silly::parse_json("{\"a\":null,\"\\u0061\":\"\\uD83D\\uDE00\"}", scratch);
    assert(doc.error == silly::JsonError.None);
    assert(silly::json_member(doc.value, "a").error == silly::JsonError.Duplicate);
    assert(silly::json_member(doc.value, "a", silly::JsonDuplicate.First).value.kind == silly::JsonKind.Null);
    let last = silly::json_member(doc.value, "a", silly::JsonDuplicate.Last);
    assert(silly::json_string(last.value).value == "😀");
    assert(scratch == "xa😀");
    assert(last.value.offset == 19);
}

fn maximum_depth() {
    var text: u8[>..] = [];
    for index in 256 {
        text.push('[');
    }
    text.push('0');
    for index in 256 {
        text.push(']');
    }
    var scratch: u8[>..] = [];
    assert(silly::parse_json(text, scratch, silly::JsonLimits {
            depth_max: 256,
            ..
        }).error == silly::JsonError.None);
    assert(silly::parse_json(text, scratch, silly::JsonLimits {
            depth_max: 255,
            ..
        }).error == silly::JsonError.DepthLimit);
}

fn raw_strings() {
    var scratch: u8[>..] = [];
    let doc = silly::parse_json("  \"plain\"  ", scratch);
    assert(doc.error == silly::JsonError.None);
    assert(doc.value.offset == 2);
    assert(doc.value.raw == "\"plain\"");
    assert(silly::json_string(doc.value).value == "plain");
    assert(scratch.len == 0);
    assert(silly::json_object(doc.value).error == silly::JsonError.Type);
}
