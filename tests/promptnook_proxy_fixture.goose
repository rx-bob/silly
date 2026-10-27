namespace pn_fixture;

import std;

extern fn pn_contract_config(item: i32, output: u8[:]) -> i64;

extern fn pn_contract_ready(port: i32) -> i32;

extern fn pn_contract_stop() -> i32;

fn config(item: i32) -> u8[>..] {
    var bytes: u8[4096] = [0; 4096];
    let count = pn_contract_config(item, bytes);
    assert(count > 0);
    var result: u8[>..] = [];
    result.append(bytes[..count]);
    return result;
}
