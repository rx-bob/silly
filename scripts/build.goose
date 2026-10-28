// Compiler modes use separate native caches so C sidecars cannot cross optimization modes.
namespace silly_check;

import os;
import std;

import.config;
import.process;

fn binary(config: Config, source: u8[:], mode: u8[:]) -> u8[>..] {
    return str(config.output, "/", safe_name(source), "-", mode);
}

fn compile(config: Config&, source: u8[:], mode: u8[:]) -> bool {
    let cache = str("GOOSE_HOME=", config.output, "/cache-", mode);
    let destination = binary(config, source, mode);
    let label = str("build-", source, "-", mode);
    return if mode == "debug" {
        command(config, label,
            ["env", cache, config.goose[..], "build", source, "--offline", "-O0", "--debug", "-o", destination])
    } else {
        command(config, label, ["env", cache, config.goose[..], "build", source, "--offline", "-O2", "-o", destination])
    };
}

fn run_binary(config: Config&, source: u8[:], mode: u8[:]) {
    if compile(config, source, mode) {
        let destination = binary(config, source, mode);
        command(config, str("run-", source, "-", mode), [argument(destination[..])]);
    }
}
