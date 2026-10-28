// Canonical formatter config applies everywhere except the documented writable-FFI slice modules.
namespace silly_check;

import os;
import std;

import.config;
import.discover;

fn style_batch(config: Config&, files: (const u8[:])[:], ffi: bool, batch: i64) {
    var argv: (const u8[:])[>..] = [];
    argv.push(config.formatter);
    argv.push("check");
    argv.push("--config");
    argv.push(if ffi {
            ".goosefmt.ffi.toml"
        } else {
            ".goosefmt.toml"
        });
    for file in files {
        argv.push(file);
    }
    command(config, str("style-", if ffi {
            "ffi-"
        } else {
            "standard-"
        }, batch), argv);
}

fn style_checks(config: Config&) {
    var sources: u8[>..] = [];
    if !append_sources(sources, config.root, ".") {
        report(config, "style-root-discovery", false);
        return;
    }
    for directory in["src", "client", "examples", "reference", "tests", "scripts"] {
        if !tree_sources(sources, config.root, directory) {
            report(config, "style-discovery", false);
            return;
        }
    }
    for ffi in[false, true] {
        var files: (const u8[:])[>..] = [];
        var start: i64 = 0;
        var batch: i64 = 0;
        for end in sources.len {
            if sources[end] != '\n' {
                continue;
            }
            let path = sources[start..end];
            if ffi_fixture(path) == ffi {
                files.push(path);
            }
            if files.len == 100 {
                style_batch(config, files, ffi, batch);
                files.clear();
                batch += 1;
            }
            start = end + 1;
        }
        if files.len > 0 {
            style_batch(config, files, ffi, batch);
        }
    }
}
