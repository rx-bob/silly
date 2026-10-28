// Deterministic isolated compiler/functional verification; no publication or benchmark behavior.
namespace silly_check;

import os;
import std;

import.compiler;
import.config;
import.consumers;
import.external;
import.functional;
import.process;
import.style;

fn execute_runner() {
    var settings = config();
    if !parse_config(settings) {
        print("invalid arguments; use --help (root/output must be absolute)");
        exit(2);
    }
    if !file_exists(str(settings.root, "/silly.goose")) || !make_dir(settings.output) {
        print("repository root or output directory unavailable");
        exit(2);
    }
    print(str("verification root=", settings.root, " output=", settings.output));
    command(settings, "compiler-version", [argument(settings.goose[..]), "version"]);
    if selected(settings, "style") {
        style_checks(settings);
    }
    for mode in["debug", "optimized"] {
        if !mode_selected(settings, mode) {
            continue;
        }
        if selected(settings, "functional") {
            functional_checks(settings, mode);
        }
        if selected(settings, "compiler") {
            compiler_checks(settings, mode);
        }
        if selected(settings, "references") {
            reference_checks(settings, mode);
            external_consumers(settings, mode);
        }
        if selected(settings, "external") {
            external_checks(settings, mode);
        }
    }
    check_cancelled();
    check_process::cleanup();
    print(str("verification passed=", settings.passed, " failed=", settings.failed, " logs=", settings.output));
    exit(if settings.failed == 0 {
            0
        } else {
            1
        });
}
