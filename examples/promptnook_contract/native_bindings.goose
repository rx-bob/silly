// Canonical disposable native-state contract ABI; linked only by fixture build sidecars.
namespace promptnook_native_example;

extern fn promptnook_contract_open() -> i32;

extern fn promptnook_contract_close() -> i32;

extern fn promptnook_contract_prepare(value: i64) -> i32;

extern fn promptnook_contract_bind(value: i64) -> i32;

extern fn promptnook_contract_query() -> i32;

extern fn promptnook_contract_read() -> i64;

extern fn promptnook_contract_zip_reset(value: i64) -> i32;

extern fn promptnook_contract_zip_add(value: i64) -> i32;

extern fn promptnook_contract_zip_finish() -> i64;
