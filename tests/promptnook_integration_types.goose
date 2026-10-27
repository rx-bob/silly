// Disposable API/Portal runtime fixture; copied configuration carries no production credentials.
namespace pn_integration;

import silly from "..";

enum Route {
    Health,
    Database,
    Export,
    Upload,
    NativeUpload,
    Admin,
    Redirect
}
struct App {
    owner: silly::Owner,
    opened: bool = false,
}
struct Started {
    owner: silly::Owner
}
struct Stopped {
    owner: silly::Owner,
    opened: bool
}
struct Finished {
    handler: bool,
    lane: i64,
    data: silly::CompletionData,
}
struct Returned {
    ok: bool,
    drain: silly::DrainStatus,
    pending: bool,
}
struct Running {
    thread: i64,
    api: i32,
    portal: i32,
    wake: silly_transport::Descriptor,
}
const ZIP_BYTES: u8[9] = [80, 75, 3, 4, 0, 255, 128, 13, 10];
