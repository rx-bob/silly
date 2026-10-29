// Byte-sorted filesystem traversal identifies executable fixtures, not every helper module.
namespace silly_check;

import os;
import std;

import.config;

fn append_sources(out: u8[>..]&, root: u8[:], directory: u8[:]) -> bool {
    var listing: u8[>..] = [];
    if !list_dir(str(root, "/", directory), listing) {
        return false;
    }
    var start: i64 = 0;
    for end in listing.len {
        if listing[end] != '\n' {
            continue;
        }
        if listing.len > 16 * 1024 * 1024 || out.len > 16 * 1024 * 1024 {
            return false;
        }
        let path = str(directory, "/", listing[start..end]);
        if ends_with(path, ".goose") {
            out.append(path);
            out.push('\n');
        }
        start = end + 1;
    }
    return true;
}

fn tree_sources(out: u8[>..]&, root: u8[:], directory: u8[:]) -> bool {
    var pending: u8[>..] = [];
    pending.append(directory);
    pending.push('\n');
    var cursor: i64 = 0;
    while cursor < pending.len {
        var end = cursor;
        while pending[end] != '\n' {
            end += 1;
        }
        let current = str(pending[cursor..end]);
        var depth: i64 = 0;
        for byte in current {
            if byte == '/' {
                depth += 1;
            }
        }
        if depth >= 64 {
            return false;
        }
        cursor = end + 1;
        var listing: u8[>..] = [];
        if !list_dir(str(root, "/", current), listing) {
            return false;
        }
        var start: i64 = 0;
        for offset in listing.len {
            if listing[offset] != '\n' {
                continue;
            }
            if pending.len > 16 * 1024 * 1024 || out.len > 16 * 1024 * 1024 || listing.len > 16 * 1024 * 1024 {
                return false;
            }
            let path = str(current, "/", listing[start..offset]);
            if is_dir(str(root, "/", path)) {
                pending.append(path);
                pending.push('\n');
            } else if ends_with(path, ".goose") {
                out.append(path);
                out.push('\n');
            }
            start = offset + 1;
        }
    }
    return true;
}

fn executable_source(config: Config&, path: u8[:]) -> bool {
    var source: u8[>..] = [];
    if !read_file(str(config.root, "/", path), source) {
        report(config, str("read-source-", path), false);
        return false;
    }
    return find(source, "fn::main(") >= 0;
}

fn external_fixture(path: u8[:]) -> bool {
    return ends_with(path, "/client_transport_test.goose") || ends_with(path, "/client_http_test.goose")
        || ends_with(path, "/proxy_test.goose") || ends_with(path, "/promptnook_proxy_test.goose");
}

fn ffi_fixture(path: u8[:]) -> bool {
    if ends_with(path, "/files_fixture.goose") || ends_with(path, "/client_fixture.goose")
        || ends_with(path, "/static_portal_fixture.goose") {
        return true;
    }
    let exceptions = [
        "scripts/process.goose",
        "src/files/file_native.goose",
        "src/files/static_native.goose",
        "src/transport/transport.goose",
        "client/native.goose",
        "tests/client/client_fixture.goose",
        "tests/files/files_fixture.goose",
        "tests/integration/promptnook/promptnook_proxy_fixture.goose",
        "tests/client/proxy_fixture.goose",
        "tests/files/static_metadata_fixture.goose",
        "tests/integration/static_portal/static_portal_fixture.goose",
    ];
    for exception in exceptions {
        if path == exception {
            return true;
        }
    }
    return false;
}
