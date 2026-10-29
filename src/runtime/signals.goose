// Opt-in process signal policy. Importing this module changes no handler.
namespace silly;

extern fn silly_signals_install() -> i64;

extern fn silly_signals_requested(token: i64) -> i32;

extern fn silly_signals_uninstall(token: i64) -> i32;

struct SignalAdapter {
    ok: bool = false,
    token: i64 = 0,
    error: i32 = 0,
}

fn install_shutdown_signals() -> SignalAdapter {
    let installed = silly_signals_install();
    return SignalAdapter {
        ok: installed > 0,
        token: if installed > 0 {
            installed
        } else {
            0
        },
        error: if installed > 0 {
            0
        } else {
            (-installed)as i32
        },
    };
}

fn shutdown_signal_requested(token: i64) -> bool {
    return silly_signals_requested(token) != 0;
}

fn uninstall_shutdown_signals(adapter: SignalAdapter&) -> bool {
    let error = silly_signals_uninstall(adapter.token);
    adapter.error = error;
    if error != 0 {
        return false;
    }
    adapter.ok = false;
    adapter.token = 0;
    return true;
}
