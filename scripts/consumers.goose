// Build real reference consumers outside the library checkout, without changing their handlers.
namespace silly_check;

import os;
import std;

import.build;
import.config;

fn quoted_path(path: u8[:]) -> u8[>..] {
    var out: u8[>..] = [];
    out.push('"');
    for byte in path {
        if byte == '"' || byte == '\\' {
            out.push('\\');
        }
        if byte == '\n' {
            out.append("\\n");
        } else if byte == '\r' {
            out.append("\\r");
        } else if byte == '\t' {
            out.append("\\t");
        } else {
            out.push(byte);
        }
    }
    out.push('"');
    return out;
}

fn replace_import(source: u8[:], old: u8[:], path: u8[:]) -> u8[>..] {
    let at = find(source, old);
    assert(at >= 0);
    var result: u8[>..] = [];
    result.append(source[..at]);
    result.append(quoted_path(path));
    result.append(source[at + old.len..]);
    return result;
}

fn external_core(config: Config&, directory: u8[:], mode: u8[:]) {
    var original: u8[>..] = [];
    if !read_file(str(config.root, "/reference/app.goose"), original) {
        report(config, "external-core-source", false);
        return;
    }
    let source = replace_import(original, "\"..\"", config.root);
    let path = str(directory, "/core.goose");
    if !write_file(path, source) {
        report(config, "external-core-write", false);
        return;
    }
    compile(config, path, mode);
}

fn external_portal(config: Config&, directory: u8[:], mode: u8[:]) {
    var original: u8[>..] = [];
    if !read_file(str(config.root, "/reference/files_and_portal.goose"), original) {
        report(config, "external-portal-source", false);
        return;
    }
    let core = replace_import(original, "\"..\"", config.root);
    let client = replace_import(core, "\"../client\"", str(config.root, "/client"));
    let proxy = replace_import(client, "\"../client\"", str(config.root, "/client"));
    let source = replace_import(proxy, "\"../examples/promptnook_contract\"",
        str(config.root, "/examples/promptnook_contract"));
    let path = str(directory, "/portal.goose");
    let native = quoted_path(str(config.root, "/client/native/client.c"));
    let manifest = str("c_sources = [", native, "];\nc_libs = [\"curl\", \"z\"];\n");
    if !write_file(path, source) || !write_file(str(directory, "/portal.build"), manifest) {
        report(config, "external-portal-write", false);
        return;
    }
    compile(config, path, mode);
}

fn external_consumers(config: Config&, mode: u8[:]) {
    if config.output == config.root || starts_with(config.output, str(config.root, "/")) {
        report(config, "external-consumer-output-must-be-outside-checkout", false);
        return;
    }
    let directory = str(config.output, "/consumers-", mode);
    if !make_dir(directory) {
        report(config, "external-consumer-directory", false);
        return;
    }
    external_core(config, directory, mode);
    external_portal(config, directory, mode);
}
