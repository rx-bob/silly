// Portable runner configuration; execute from the repository root or pass --root.
namespace silly_check;

import os;
import std;

import.process;

struct Config {
    root: u8[..4096] = [],
    output: u8[..4096] = [],
    goose: u8[..4096] = [],
    formatter: u8[..4096] = [],
    python: u8[..4096] = [],
    mode: u8[..16] = [],
    group: u8[..32] = [],
    failed: i64 = 0,
    passed: i64 = 0,
}
fn config() -> Config {
    var result = Config {
    };
    let cwd = environment("PWD", "");
    result.root.append(cwd);
    result.output.append(str("/tmp/silly-check-", check_process::pid()));
    result.goose.append(environment("GOOSE", "goose"));
    result.formatter.append(environment("GOOSEFMT", "goosefmt"));
    result.python.append(environment("PYTHON", "python3"));
    result.mode.append("both");
    result.group.append("all");
    return result;
}

fn parse_config(config: Config&) -> bool {
    let argv = args();
    var index: i64 = 1;
    while index < argv.len {
        if argv[index] == "--help" {
            print("check --mode debug|optimized|both --group all|functional|compiler|style|references|external");
            print("      --root PATH --output PATH --goose PATH --formatter PATH --python PATH");
            exit(0);
        }
        if index + 1 >= argv.len || argv[index + 1].len > 4000 {
            return false;
        }
        let name = argv[index];
        let value = argv[index + 1];
        if name == "--root" {
            config.root.clear();
            config.root.append(value);
        } else if name == "--output" {
            config.output.clear();
            config.output.append(value);
        } else if name == "--goose" {
            config.goose.clear();
            config.goose.append(value);
        } else if name == "--formatter" {
            config.formatter.clear();
            config.formatter.append(value);
        } else if name == "--python" {
            config.python.clear();
            config.python.append(value);
        } else if name == "--mode" && value.len <= 16 {
            config.mode.clear();
            config.mode.append(value);
        } else if name == "--group" && value.len <= 32 {
            config.group.clear();
            config.group.append(value);
        } else {
            return false;
        }
        index += 2;
    }
    return (config.mode == "both" || config.mode == "debug" || config.mode == "optimized")
        && (config.group == "all" || config.group == "functional" || config.group == "compiler"
        || config.group == "style" || config.group == "references" || config.group == "external")
        && config.root.len > 0 && config.root[0] == '/' && config.output.len > 0 && config.output[0] == '/';
}

fn selected(config: Config, group: u8[:]) -> bool {
    return config.group == "all" || config.group == group;
}

fn mode_selected(config: Config, mode: u8[:]) -> bool {
    return config.mode == "both" || config.mode == mode;
}

fn safe_name(path: u8[:]) -> u8[>..] {
    var name: u8[>..] = [];
    for byte in path {
        name.push(if byte == '/' || byte == '.' {
                '_'
            } else {
                byte
            });
    }
    return name;
}

fn logfile(config: Config, label: u8[:]) -> u8[>..] {
    return str(config.output, "/", safe_name(label), ".log");
}

fn report(config: Config&, label: u8[:], success: bool) {
    check_cancelled();
    if success {
        config.passed += 1;
        print(str("PASS ", label));
    } else {
        config.failed += 1;
        print(str("FAIL ", label, " (", logfile(config, label), ")"));
    }
    flush_stdout();
}

fn command(config: Config&, label: u8[:], argv: (const u8[:])[:]) -> bool {
    check_cancelled();
    let result = check_process::run(argv, config.root, logfile(config, label));
    let success = check_process::ok(result);
    report(config, label, success);
    if !success {
        print(str("  process state=", result.state, " exit/signal=", result.code, " errno=", result.error));
        var output: u8[>..] = [];
        if check_process::read_log(logfile(config, label), output, true) {
            let tail = if output.len > 4096 {
                output.len - 4096
            } else {
                0
            };
            print(output[tail..]);
        }
    }
    return success;
}

fn environment(name: u8[:], fallback: u8[:]) -> u8[>..] {
    var value: u8[>..] = [];
    if !env(name, value) {
        value.append(fallback);
    }
    if value.len > 4000 {
        abort("runner environment path exceeds limit");
    }
    return value;
}

fn argument(value: u8[:]) -> const u8[:] {
    return value;
}

fn check_cancelled() {
    let signal = check_process::cancelled();
    if signal != 0 {
        check_process::cleanup();
        print("verification cancelled");
        exit((128 + signal)as i32);
    }
}
