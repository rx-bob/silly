// Limits account for every decoded byte and empty pair, including borrowed fast paths.
namespace query_limits_test;

import silly from "..";

import std;

fn empty() {
    var scratch: u8[>..] = [];
    let options = silly::QueryOptions {
        input_bytes_max: 0,
        pairs_max: 0,
        decoded_bytes_max: 0,
        ..
    };
    let pairs = silly::parse_query("", scratch, options);
    assert(pairs.error == silly::QueryError.None);
    assert(pairs.entries.len == 0);
    assert(silly::parse_query("&", scratch, silly::QueryOptions {
            pairs_max: 0,
            ..
        }).error
        == silly::QueryError.PairLimit);
    assert(silly::parse_query("flag", scratch, silly::QueryOptions {
            decoded_bytes_max: 3,
            ..
        }).error
        == silly::QueryError.DecodedLimit);
    assert(scratch.len == 0);
}

fn atomic() {
    var scratch: u8[>..] = [];
    scratch.append("xx");
    assert(silly::parse_query("=%41&=%42", scratch, silly::QueryOptions {
            pairs_max: 1,
            ..
        }).error
        == silly::QueryError.PairLimit);
    assert(scratch == "xx");
    assert(silly::parse_query("=%41", scratch, silly::QueryOptions {
            decoded_bytes_max: 2,
            ..
        }).error
        == silly::QueryError.DecodedLimit);
    assert(scratch == "xx");
    assert(silly::parse_query("=%41&=%XX", scratch).error == silly::QueryError.InvalidEscape);
    assert(scratch == "xx");
    let exact = silly::parse_query("=%41", scratch, silly::QueryOptions {
            decoded_bytes_max: 3,
            ..
        });
    assert(exact.error == silly::QueryError.None);
    assert(exact.entries[0].value == "A");
    assert(scratch == "xxA");
}

fn raw_limits() {
    var iterator = silly::raw_query_pairs("x&", silly::QueryOptions {
            pairs_max: 1,
            ..
        });
    assert(silly::next_raw_query(iterator).present);
    let end = silly::next_raw_query(iterator);
    assert(!end.present);
    assert(end.error == silly::QueryError.PairLimit);
    assert(silly::next_raw_query(iterator).error == silly::QueryError.PairLimit);
    let presence = silly::raw_key_present("x&", "x", silly::QueryOptions {
            pairs_max: 1,
            ..
        });
    assert(presence.error == silly::QueryError.PairLimit);
    assert(!presence.present);
    var invalid = silly::raw_query_pairs("x", silly::QueryOptions {
            separators: ";",
            ..
        });
    assert(silly::next_raw_query(invalid).error == silly::QueryError.InvalidOptions);
    var large = silly::raw_query_pairs("abc", silly::QueryOptions {
            input_bytes_max: 2,
            ..
        });
    assert(silly::next_raw_query(large).error == silly::QueryError.InputLimit);
}

fn::main() {
    query_limits_test::empty();
    query_limits_test::atomic();
    query_limits_test::raw_limits();
    print("query boundary and atomicity tests passed");
}
