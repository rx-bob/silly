// Ordered byte-oriented query decoding preserves exact raw syntax and borrowed storage.
namespace query_test;

import silly from "..";

import std;

fn basics() {
    var scratch: u8[>..] = [];
    let pairs = silly::parse_query("a=one&a=two&flag&empty=&=value&&tail=", scratch);
    assert(pairs.error == silly::QueryError.None);
    assert(pairs.entries.len == 7);
    assert(silly::get(pairs, "a").value == "one");
    assert(silly::get(pairs, "flag").present);
    assert(silly::get(pairs, "flag").value == "");
    assert(!pairs.entries[2].has_equals);
    assert(pairs.entries[3].has_equals);
    assert(pairs.entries[5].raw_key == "");
    assert(!pairs.entries[5].has_equals);
    assert(scratch.len == 0);
    var values = silly::query_values(pairs, "a");
    assert(silly::next_query_value(values).value == "one");
    assert(silly::next_query_value(values).value == "two");
    assert(!silly::next_query_value(values).present);
    assert(!silly::get(pairs, "missing").present);
}

fn transformed() {
    var scratch: u8[>..] = [];
    let pairs = silly::parse_query("a+b=%252F%26%3D&nul=%00&utf=%C3%A9&raw=hello", scratch);
    assert(pairs.error == silly::QueryError.None);
    assert(pairs.entries[0].raw_key == "a+b");
    assert(pairs.entries[0].key == "a b");
    assert(pairs.entries[0].value == "%2F&=");
    assert(pairs.entries[1].value.len == 1);
    assert(pairs.entries[1].value[0] == 0);
    assert(pairs.entries[2].value == "\xC3\xA9");
    assert(silly::get(pairs, "raw").value == "hello");
    assert(scratch.len == 11);
}

fn raw_and_empty() {
    assert(!silly::raw_query("/path").present);
    assert(silly::raw_query("/path?").present);
    var empty = silly::raw_query_pairs("");
    assert(!silly::next_raw_query(empty).present);
    var iterator = silly::raw_query_pairs("&&");
    for index in 3 {
        let item = silly::next_raw_query(iterator);
        assert(item.present);
        assert(item.pair.raw_key == "");
        assert(!item.pair.has_equals);
    }
    assert(!silly::next_raw_query(iterator).present);
    assert(silly::raw_key_present("%61=x&a&bad=%", "a").present);
    assert(!silly::raw_key_present("%61=x&bad=%", "a").present);
}

fn invalid_and_limits() {
    var scratch: u8[>..] = [];
    scratch.append("prefix");
    let invalid = silly::parse_query("valid=%41&bad=%gg", scratch);
    assert(invalid.error == silly::QueryError.InvalidEscape);
    assert(invalid.entries.len == 0);
    assert(scratch == "prefix");
    let literal = silly::parse_query("bad=%gg%41+%", scratch, silly::QueryOptions {
            invalid_escape: silly::InvalidEscape.Literal,
            ..
        });
    assert(literal.error == silly::QueryError.None);
    assert(silly::get(literal, "bad").value == "%ggA %");
}

fn limits() {
    var scratch: u8[>..] = [];
    assert(silly::parse_query("a=1&b=2", scratch, silly::QueryOptions {
            pairs_max: 1,
            ..
        }).error
        == silly::QueryError.PairLimit);
    assert(silly::parse_query("a=1", scratch, silly::QueryOptions {
            input_bytes_max: 2,
            ..
        }).error
        == silly::QueryError.InputLimit);
    assert(silly::parse_query("a=%41", scratch, silly::QueryOptions {
            decoded_bytes_max: 1,
            ..
        }).error
        == silly::QueryError.DecodedLimit);
    assert(silly::parse_query("a=1", scratch, silly::QueryOptions {
            pairs_max: -1,
            ..
        }).error
        == silly::QueryError.InvalidOptions);
    assert(scratch.len == 0);
    let exact = silly::parse_query("a=%41", scratch, silly::QueryOptions {
            pairs_max: 1,
            input_bytes_max: 5,
            decoded_bytes_max: 2,
            ..
        });
    assert(exact.error == silly::QueryError.None);
    assert(exact.entries[0].value == "A");
}

fn boundaries() {
    var scratch: u8[>..] = [];
    let empty = silly::parse_query("", scratch, silly::QueryOptions {
            pairs_max: 0,
            input_bytes_max: 0,
            decoded_bytes_max: 0,
            ..
        });
    assert(empty.error == silly::QueryError.None);
    assert(empty.entries.len == 0);
    assert(silly::parse_query("&", scratch, silly::QueryOptions {
            pairs_max: 1,
            ..
        }).error
        == silly::QueryError.PairLimit);
    assert(silly::parse_query("a=1", scratch, silly::QueryOptions {
            separators: ";",
            ..
        }).error
        == silly::QueryError.InvalidOptions);
    var iterator = silly::raw_query_pairs("a=1&b=2", silly::QueryOptions {
            pairs_max: 1,
            ..
        });
    assert(silly::next_raw_query(iterator).present);
    assert(silly::next_raw_query(iterator).error == silly::QueryError.PairLimit);
    assert(silly::next_raw_query(iterator).error == silly::QueryError.PairLimit);
    assert(silly::raw_key_present("a=1&b=2", "a", silly::QueryOptions {
            pairs_max: 1,
            ..
        }).error
        == silly::QueryError.PairLimit);
    scratch.append("xx");
    assert(silly::parse_query("a=%41", scratch, silly::QueryOptions {
            decoded_bytes_max: 2,
            ..
        }).error
        == silly::QueryError.DecodedLimit);
    assert(scratch == "xx");
    let ampersand = silly::parse_query("a=1;b=2", scratch);
    assert(ampersand.entries.len == 1);
    assert(ampersand.entries[0].value == "1;b=2");
}

fn views() {
    var scratch: u8[>..] = [];
    let view = silly::parse_query_view("a=1&a=%32&&Environment=prod", scratch);
    assert(view.error == silly::QueryError.None);
    assert(view.count == 4);
    assert(silly::get(view, "a").value == "1");
    var values = silly::query_values(view, "a");
    assert(silly::next_query_value(values).value == "1");
    assert(silly::next_query_value(values).value == "2");
    assert(!silly::next_query_value(values).present);
    var iterator = silly::query_iterator(view);
    assert(silly::next_query_pair(iterator).pair.value == "1");
    let decoded = silly::next_query_pair(iterator);
    assert(decoded.pair.value == "2");
    assert(decoded.pair.raw_value == "%32");
    assert(decoded.pair.has_equals);
    let empty = silly::next_query_pair(iterator);
    assert(empty.present);
    assert(!empty.pair.has_equals);
    assert(silly::next_query_pair(iterator).pair.key == "Environment");
    assert(!silly::next_query_pair(iterator).present);
    let excluded = ["environment"];
    let filtered = silly::without_query_keys(view, excluded, silly::KeyMatch.AsciiIgnoreCase);
    assert(filtered.entries.len == 3);
    assert(filtered.entries[1].value == "2");
}

fn filtering() {
    var scratch: u8[>..] = [];
    let pairs = silly::parse_query("Environment=prod;a=1&environment=dev&a=2&&flag", scratch,
        silly::QueryOptions {
            separators: "&;",
            ..
        });
    assert(pairs.error == silly::QueryError.None);
    let filtered = silly::without_query_keys(pairs, ["environment"], silly::KeyMatch.AsciiIgnoreCase);
    assert(filtered.entries.len == 4);
    assert(filtered.entries[0].key == "a");
    assert(filtered.entries[1].value == "2");
    assert(filtered.entries[2].key == "");
    assert(!filtered.entries[3].has_equals);
    assert(pairs.entries.len == 6);
}

fn::main() {
    query_test::basics();
    query_test::transformed();
    query_test::raw_and_empty();
    query_test::invalid_and_limits();
    query_test::limits();
    query_test::filtering();
    query_test::boundaries();
    query_test::views();
    print("bounded query decoding passed");
}
