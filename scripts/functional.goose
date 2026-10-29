// Every standalone test is built/run independently; helpers never become accidental test programs.
namespace silly_check;

import os;
import std;

import.build;
import.config;
import.discover;

fn functional_checks(config: Config&, mode: u8[:]) {
    var sources: u8[>..] = [];
    if !tree_sources(sources, config.root, "tests") {
        report(config, "functional-discovery", false);
        return;
    }
    var start: i64 = 0;
    var found: i64 = 0;
    for end in sources.len {
        if sources[end] != '\n' {
            continue;
        }
        let source = sources[start..end];
        if source != "tests/all.goose" && !starts_with(source, "tests/lifetimes/")
            && !external_fixture(source) && executable_source(config, source) {
            found += 1;
            run_binary(config, source, mode);
        }
        start = end + 1;
    }
    if found == 0 {
        report(config, "empty-executable-inventory", false);
    }
}

fn reference_checks(config: Config&, mode: u8[:]) {
    var sources: u8[>..] = [];
    if !tree_sources(sources, config.root, "examples") || !append_sources(sources, config.root, "reference") {
        report(config, "reference-discovery", false);
        return;
    }
    var start: i64 = 0;
    var found: i64 = 0;
    for end in sources.len {
        if sources[end] != '\n' {
            continue;
        }
        let source = sources[start..end];
        if executable_source(config, source) {
            found += 1;
            compile(config, source, mode);
        }
        start = end + 1;
    }
    if found == 0 {
        report(config, "empty-executable-inventory", false);
    }
}
