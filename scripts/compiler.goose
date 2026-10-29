// Compile-negative contracts and targeted optimizer diagnostics are independent gates.
namespace silly_check;

import os;
import std;

import.build;
import.config;
import.discover;
import.process;
import.rejections;

fn rejection(config: Config&, fixture: Rejection, mode: u8[:]) {
    let label = str("reject-", fixture.source, "-", mode);
    var result = check_process::Result {
    };
    if mode == "debug" {
        result = check_process::run([argument(config.goose[..]), "check", fixture.source, "-O0", "--debug"],
            config.root, logfile(config, label));
    } else {
        result = check_process::run([argument(config.goose[..]), "check", fixture.source, "-O2"],
            config.root, logfile(config, label));
    }
    var output: u8[>..] = [];
    let read = check_process::read_log(logfile(config, label), output);
    report(config, label, result.state == 1 && result.code != 0 && read && find(output, fixture.diagnostic) >= 0);
}

fn compiler_checks(config: Config&, mode: u8[:]) {
    rejection_inventory(config);
    for fixture in REJECTIONS {
        rejection(config, fixture, mode);
    }
    run_binary(config, "tests/lifetimes/scoped_views.goose", mode);
    run_binary(config, "reference/dispatch_proof.goose", mode);
    run_binary(config, "tests/support/api_contract_test.goose", mode);
    if mode != "optimized" {
        return;
    }
    let targets = ["examples/hello.goose", "tests/routing/route_plan_test.goose", "tests/http/http_head_test.goose",
        "tests/streaming/stream_http_test.goose", "tests/integration/general_web/general_web_test.goose"];
    for target in targets {
        let label = str("analysis-", target);
        if command(config, label, [argument(config.goose[..]), "check", target, "-O2", "--stacks", "--bce-lines"]) {
            var output: u8[>..] = [];
            let read = check_process::read_log(logfile(config, label), output);
            report(config, str("analysis-contract-", target), read && find(output, "bce:") >= 0
                && find(output, "data stacks:") >= 0 && find(output, "bce-line:") >= 0);
        }
    }
}

fn rejection_inventory(config: Config&) {
    var sources: u8[>..] = [];
    if !append_sources(sources, config.root, "tests/lifetimes") {
        report(config, "rejection-discovery", false);
        return;
    }
    var start: i64 = 0;
    var found: i64 = 0;
    for end in sources.len {
        if sources[end] != '\n' {
            continue;
        }
        let source = sources[start..end];
        if ends_with(source, "_rejected.goose") {
            var known = false;
            for fixture in REJECTIONS {
                if fixture.source == source {
                    known = true;
                }
            }
            report(config, str("rejection-inventory-", source), known);
            found += 1;
        }
        start = end + 1;
    }
    report(config, "rejection-inventory-count", found == REJECTIONS.len);
}
