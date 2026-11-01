// Goose replaces shell wrappers. Ruby files remain disposable HTTP/TLS protocol fixtures.
namespace silly_check;

import json;
import os;
import std;

import.build;
import.config;
import.process;

fn tls_files(config: Config&, directory: u8[:], mode: u8[:]) -> bool {
    if !make_dir(directory) {
        report(config, "tls-directory", false);
        return false;
    }
    let ca_key = str(directory, "/ca.key");
    let ca = str(directory, "/ca.pem");
    let key = str(directory, "/server.key");
    let request = str(directory, "/server.csr");
    let certificate = str(directory, "/server.pem");
    let extensions = str(directory, "/extensions");
    if !write_file(extensions, "subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\n") {
        report(config, str("tls-extensions-", mode), false);
        return false;
    }
    return command(config, str("tls-ca-", mode), ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", ca_key, "-out", ca, "-days", "1", "-subj", "/CN=silly-disposable-test-ca"])
        && command(config, str("tls-request-", mode), ["openssl", "req", "-newkey", "rsa:2048", "-nodes",
        "-keyout", key, "-out", request, "-subj", "/CN=localhost"])
        && command(config, str("tls-certificate-", mode), ["openssl", "x509", "-req", "-in", request,
        "-CA", ca, "-CAkey", ca_key, "-CAcreateserial", "-out", certificate,
        "-days", "1", "-extfile", extensions]);
}

fn ready_port(path: u8[:], key: u8[:]) -> u8[>..] {
    var text: u8[>..] = [];
    if !read_file(path, text) {
        return [];
    }
    var nodes: json::Node[>..] = [];
    var scratch: u8[>..] = [];
    let root, error = json::parse(text, nodes, scratch);
    let value = json::member(root, key);
    guard value else {
        return [];
    }
    var output: u8[>..] = [];
    if error.len == 0 {
        match value.val {
            Int number => {
                if number.v > 0 && number.v <= 65535 {
                    output.append(str(number.v));
                }
            },
            _ => {
            },
        }
    }
    return output;
}

fn wait_fixture(process: check_process::Result&, ready: u8[:]) -> bool {
    let deadline = clock_ns() + 10000000000;
    while clock_ns() < deadline {
        check_cancelled();
        check_process::poll(process);
        if process.state != 0 {
            return false;
        }
        if ready_port(ready, "http").len > 0 {
            return true;
        }
        sleep_ms(20);
    }
    return false;
}

fn client_fixture(config: Config&, mode: u8[:], tls: bool, directory: u8[:]) {
    let source = if tls {
        "tests/client/client_transport_test.goose"
    } else {
        "tests/client/client_http_test.goose"
    };
    if !compile(config, source, mode) {
        return;
    }
    let ready = str(config.output, "/ready-", mode, if tls {
            "-transport.json"
        } else {
            "-http.json"
        });
    if file_exists(ready) {
        delete_file(ready);
    }
    var fixture = check_process::Result {
    };
    if tls {
        fixture = check_process::spawn([argument(config.ruby[..]), "tests/client/client_fixture.rb", ready,
            str(directory, "/server.pem"), str(directory, "/server.key")],
            config.root, logfile(config, str("fixture-transport-", mode)));
    } else {
        fixture = check_process::spawn([argument(config.ruby[..]),
            "tests/client/client_http_fixture.rb", ready],
            config.root, logfile(config, str("fixture-http-", mode)));
    }
    if wait_fixture(fixture, ready) {
        run_client(config, source, mode, ready, directory);
    } else {
        report(config, str("fixture-ready-", source, "-", mode), false);
    }
    check_process::stop(fixture);
}

fn run_client(config: Config&, source: u8[:], mode: u8[:], ready: u8[:], directory: u8[:]) {
    let http = str("SILLY_CLIENT_HTTP=", ready_port(ready, "http"));
    let https = str("SILLY_CLIENT_HTTPS=", ready_port(ready, "https"));
    let refused = str("SILLY_CLIENT_REFUSED=", ready_port(ready, "refused"));
    let stall = str("SILLY_CLIENT_STALL=", ready_port(ready, "stall"));
    let ca = str("SILLY_CLIENT_CA=", directory, "/ca.pem");
    let executable = binary(config, source, mode);
    command(config, str("run-", source, "-", mode), ["env", http, https, refused, stall, ca, executable]);
}

fn proxy_fixture(config: Config&, mode: u8[:], consumer: bool, directory: u8[:]) {
    let source = if consumer {
        "tests/integration/promptnook/promptnook_proxy_test.goose"
    } else {
        "tests/client/proxy_test.goose"
    };
    if !compile(config, source, mode) {
        return;
    }
    let executable = binary(config, source, mode);
    if consumer {
        command(config, str("run-", source, "-", mode),
            [argument(config.ruby[..]),
            "tests/integration/promptnook/promptnook_proxy_fixture.rb", executable, directory]);
    } else {
        command(config, str("run-", source, "-", mode),
            [argument(config.ruby[..]), "tests/client/proxy_fixture.rb", executable]);
    }
}

fn native_files(config: Config&, mode: u8[:]) {
    let executable = str(config.output, "/native-files-", mode);
    let flag = if mode == "debug" {
        "-O0"
    } else {
        "-O2"
    };
    if command(config, str("build-native-files-", mode),
        ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", flag,
        "-g", "-pthread", "-DSILLY_FILES_TEST", "tests/files/files_native_test.c", "native/files.c", "-o",
        executable]) {
        command(config, str("run-native-files-", mode), [argument(executable[..])]);
    }
}

fn external_checks(config: Config&, mode: u8[:]) {
    let directory = str(config.output, "/tls-", mode);
    let tls = tls_files(config, directory, mode);
    if tls {
        client_fixture(config, mode, true, directory);
    }
    client_fixture(config, mode, false, directory);
    proxy_fixture(config, mode, false, directory);
    if tls {
        proxy_fixture(config, mode, true, directory);
    }
    native_files(config, mode);
}
