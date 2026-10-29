// Literal argv, working directory, environment, exit classification and descendant cleanup.
namespace check_process_test;

import process from "../../scripts";
import silly from "../../";

import os;
import std;

extern fn silly_check_test_reaped(pid: i64) -> i32;

extern fn silly_check_test_path(restore: i32) -> i32;

fn run(directory: u8[:]) {
    let log = str(directory, "/literal.log");
    let literal = "a space;$(must-not-run)`nor-this`";
    let code = str("import os,sys; print(sys.argv[1]); ",
        "print(os.getcwd()==os.path.realpath(sys.argv[2])); print(os.environ['SILLY_ARG_TEST'])");
    let result = check_process::run(["env", "SILLY_ARG_TEST=literal;$()", "python3", "-c", code, literal, directory],
        directory, log);
    assert(check_process::ok(result));
    assert(silly_check_test_reaped(result.pid) == 1);
    var output: u8[>..] = [];
    assert(read_file(log, output));
    assert(output == str(literal, "\nTrue\nliteral;$()\n"));
    let failure = check_process::run(["python3", "-c", "raise SystemExit(7)"], directory, log);
    assert(failure.state == 1);
    assert(failure.code == 7);
    assert(silly_check_test_reaped(failure.pid) == 1);
    let missing = check_process::run(["/silly/no-such-executable"], directory, log);
    assert(missing.state == 3);
    assert(missing.pid == 0);
    let script = str(directory, "/not-an-executable");
    assert(write_file(script, "echo forbidden-shell-fallback\n"));
    assert(check_process::ok(check_process::run(["chmod", "+x", script], directory, log)));
    let executable: const u8[:] = script;
    let not_executable = check_process::run([executable], directory, log);
    assert(not_executable.state == 3);
    assert(delete_file(script));
    assert(delete_file(log));
}

fn relative_paths(directory: u8[:]) {
    let log = str(directory, "/path.log");
    let tool = str(directory, "/tool");
    assert(check_process::ok(check_process::run(["ln", "-s", "/bin/echo", tool], directory, log)));
    assert(check_process::ok(check_process::run(["./tool", "relative"], directory, log)));
    assert(silly_check_test_path(0) == 1);
    let result = check_process::run(["tool", "relative PATH"], directory, log);
    assert(silly_check_test_path(1) == 1);
    assert(check_process::ok(result));
    var output: u8[>..] = [];
    assert(read_file(log, output));
    assert(output == "relative PATH\n");
    assert(delete_file(tool));
    assert(delete_file(log));
}

fn log_limits(directory: u8[:]) {
    let log = str(directory, "/large.log");
    let data = str(directory, "/artifact");
    let code = "import sys; open(sys.argv[1], 'wb').write(b'x'*(20*1024*1024)); print('retained')";
    assert(check_process::ok(check_process::run(["python3", "-I", "-c", code, data], directory, log)));
    var output: u8[>..] = [];
    assert(check_process::read_log(log, output));
    assert(output == "retained\n");
    assert(!check_process::read_log(data, output));
    assert(output.len == 0);
    assert(check_process::read_log(data, output, true));
    assert(output.len == 4096);
    for byte in output {
        assert(byte == 'x');
    }
    assert(delete_file(data));
    assert(delete_file(log));
}

fn timeout(directory: u8[:]) {
    let log = str(directory, "/timeout.log");
    let code = str("import subprocess,signal,time\n",
        "child=subprocess.Popen(['python3','-c','import time; time.sleep(30)'])\n",
        "def stop(sig, frame):\n child.wait(timeout=2)\n print('child-reaped',flush=True)\n raise SystemExit(0)\n",
        "signal.signal(signal.SIGTERM,stop)\nprint('ready',flush=True)\ntime.sleep(30)\n");
    var result = check_process::spawn(["python3", "-u", "-c", code], directory, log);
    assert(result.state == 0);
    check_process::wait(result, 300);
    assert(result.state == 4);
    assert(silly_check_test_reaped(result.pid) == 1);
    var output: u8[>..] = [];
    assert(read_file(log, output));
    assert(find(output, "child-reaped") >= 0);
    assert(delete_file(log));
}

fn::main() {
    let directory = str("/tmp/silly process contract ", check_process::pid());
    assert(make_dir(directory));
    check_process_test::run(directory);
    check_process_test::timeout(directory);
    check_process_test::relative_paths(directory);
    check_process_test::log_limits(directory);
    check_process::cleanup();
    assert(delete_dir(directory));
    print("literal argv, process status, timeout and child cleanup passed");
}
