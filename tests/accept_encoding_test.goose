namespace accept_encoding_test;

import accept_encoding from "../src";

import std;

fn check(value: u8[:], gzip: i32, identity: i32, valid: bool = true) {
    let result = silly::parse_accept_encoding(value);
    assert(result.gzip == gzip);
    assert(result.identity == identity);
    assert(result.valid == valid);
}

fn::main() {
    accept_encoding_test::check("", 0, 1000);
    accept_encoding_test::check("gzip", 1000, 1000);
    accept_encoding_test::check("GZIP;q=0.25, identity;q=0.8", 250, 800);
    accept_encoding_test::check("gzip;q=0, *;q=1", 0, 1000);
    accept_encoding_test::check("gzip;q=1, *;q=0", 1000, 0);
    accept_encoding_test::check("*;q=0,identity;q=0.5", 0, 500);
    accept_encoding_test::check("gzip;q=1,gzip;q=0", 0, 1000);
    accept_encoding_test::check("gzip;q=0,gzip;q=1", 0, 1000);
    accept_encoding_test::check("deflate;q=1, gzip;q=0.001", 1, 1000);
    accept_encoding_test::check("gzip;q=1.000", 1000, 1000);
    accept_encoding_test::check("gzip;q=0.", 0, 1000);
    for bad in["gzip;q=1.001", "gzip;q=.5", "gzip;q=0.0001", "gzip;q=-1", "gzip;other=x"] {
        accept_encoding_test::check(bad, 0, 1000, false);
    }
    accept_encoding_test::check("identity;q=0,gzip;q=no", 0, 0, false);
    assert(silly::parse_accept_encoding("gzip", false).gzip == 0);
    print("accept encoding qualities and exclusions passed");
}
