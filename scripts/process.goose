// Canonical native argv/process boundary; no shell strings or borrowed data retained by C.
namespace check_process;

import std;

struct Result {
    pid: i64 = 0,
    state: i64 = 3,
    code: i64 = -1,
    error: i64 = 0,
}
extern "silly_check_spawn" fn native_spawn(argv: const u8[:], cwd: const u8[:], log: const u8[:], result: Result&);

extern "silly_check_poll" fn poll(result: Result&);

extern "silly_check_wait" fn wait(result: Result&, timeout_ms: i64);

extern "silly_check_stop" fn stop(result: Result&);

extern "silly_check_cleanup" fn cleanup();

extern "silly_check_pid" fn pid() -> i64;

extern "silly_check_cancelled" fn cancelled() -> i64;

fn spawn(argv: (const u8[:])[:], cwd: u8[:], log: u8[:]) -> Result {
    var result = Result {
    };
    var packed: u8[>..] = [];
    for argument in argv {
        if argument.len + 1 > 65536 - packed.len {
            return result;
        }
        for byte in argument {
            if byte == 0 {
                return result;
            }
        }
        packed.append(argument);
        packed.push(0);
    }
    native_spawn(packed, cwd, log, result);
    return result;
}

fn run(argv: (const u8[:])[:], cwd: u8[:], log: u8[:], timeout_ms: i64 = 300000) -> Result {
    var result = spawn(argv, cwd, log);
    wait(result, timeout_ms);
    return result;
}

fn ok(result: Result) -> bool {
    return result.state == 1 && result.code == 0;
}

// Writable output exists only during this synchronous read; no C pointer is retained.
extern "silly_check_read_log" fn native_read_log(path: const u8[:], output: u8[:], tail: i64) -> i64;

fn read_log(path: u8[:], output: u8[>..]&, tail: bool = false) -> bool {
    let cap = if tail {
        4096
    } else {
        16 * 1024 * 1024
    };
    output.resize(cap, 0);
    let count = native_read_log(path, output, if tail {
            1
        } else {
            0
        });
    if count < 0 {
        output.clear();
        return false;
    }
    output.resize(count, 0);
    return true;
}
