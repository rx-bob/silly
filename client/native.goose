// Every borrowed slice is consumed synchronously; callbacks retain only native-owned slots.
namespace silly_client;

extern fn silly_client_start(options: const i64[:], ca_file: const u8[:]) -> i64;

extern fn silly_client_submit(epoch: i64, url: const u8[:]) -> i64;

extern fn silly_client_poll(epoch: i64, token: i64, fields: i64[:]) -> i64;

extern fn silly_client_read(epoch: i64, token: i64, output: u8[:]) -> i64;

extern fn silly_client_headers(epoch: i64, token: i64, output: u8[:]) -> i64;

extern fn silly_client_cancel(epoch: i64, token: i64) -> i64;

extern fn silly_client_release(epoch: i64, token: i64) -> i64;

extern fn silly_client_wake_fd(epoch: i64) -> i64;

extern fn silly_client_drain(epoch: i64) -> i64;

extern fn silly_client_stop(epoch: i64) -> i64;

extern fn silly_client_finish(epoch: i64) -> i64;

extern fn silly_client_request(epoch: i64, url: const u8[:], method: const u8[:],
    headers: const u8[:], body: const u8[:], options: const i64[:]) -> i64;

extern fn silly_client_upload(epoch: i64, token: i64, bytes: const u8[:]) -> i64;

extern fn silly_client_upload_end(epoch: i64, token: i64) -> i64;

extern fn silly_client_response(epoch: i64, token: i64, fields: i64[:]) -> i64;

extern fn silly_client_redirect_url(epoch: i64, token: i64, output: u8[:]) -> i64;
