// Ordinary response helpers share one lifecycle, exact bytes and bounded metadata.
namespace responses_test;

import silly from "..";

import std;

enum Kind {
    Text,
    Empty,
    Bytes,
    Attachment,
    Redirect,
    JsonBytes,
    Json,
    Local,
}
struct Case {
    kind: Kind,
    status: i32 = 200,
    payload: const u8[:] = "",
    options: silly::BodyOptions = silly::BodyOptions {
    },
    name: const u8[:] = "file.bin",
    duplicate: bool = false,
}
struct App {
    continued: bool = false,
}
type Context = silly::Context<App, silly::NoStream>;

fn handle(ctx: Context&, item: Case) {
    if item.duplicate {
        ctx.respond_empty(204);
    }
    match item.kind {
        Text => {
            ctx.text(item.status, item.payload);
        },
        Empty => {
            ctx.empty(item.status);
        },
        Bytes => {
            ctx.bytes(item.status, item.payload, item.options);
        },
        Attachment => {
            ctx.attachment(item.status, item.payload, silly::Attachment {
                    filename: item.name,
                    content_type: item.options.content_type,
                    charset: item.options.charset,
                });
        },
        Redirect => {
            ctx.redirect(item.status, item.payload);
        },
        JsonBytes => {
            ctx.json_bytes(item.status, item.payload);
        },
        Json => {
            let number: i64 = 42;
            ctx.json(item.status, number);
        },
        Local => {
            assert(ctx.respond_bytes(item.status, item.payload, item.options) == silly::ResponseError.OutputLimit);
        },
    }
    ctx.app.continued = true;
}

fn has(response: silly::Response&, name: u8[:], expected: u8[:]) -> bool {
    let index = silly::find_header(response.header_fields, response.header_bytes, name);
    if index < 0 {
        return false;
    }
    return silly::header_view(response.header_fields, response.header_bytes, index).value == expected;
}

fn verify(item: Case, expected: u8[:], error: silly::ResponseError = silly::ResponseError.None,
    limits: silly::Limits = silly::Limits {
    }) {
    var fields: silly::HeaderField[>..] = [];
    var headers: u8[>..] = [];
    var output: u8[>..] = [];
    var response = silly::Response {
        limits: limits,
        header_fields: fields,
        header_bytes: headers,
        output: output,
        ..
    };
    var app = App {
    };
    let request = silly::Request {
        method: "GET",
        target: "/",
        ..
    };
    var ctx = Context {
        request: request,
        response: response,
        app: app,
        ..
    };
    silly::endpoint(ctx, item, handle);
    assert(response.error == error);
    assert(app.continued == (error == silly::ResponseError.None || item.kind == Kind.Local));
    assert(headers.len <= limits.header_bytes_max);
    assert(output.len <= limits.output_bytes_max);
    if error != silly::ResponseError.None {
        assert(response.phase == silly::ResponsePhase.Failed);
        return;
    }
    assert(response.phase == silly::ResponsePhase.Prepared);
    assert(response.status == item.status);
    assert(output == expected);
    verify_headers(response, item);
}

fn verify_headers(response: silly::Response&, item: Case) {
    if item.kind == Kind.Text {
        assert(has(response, "Content-Type", "text/plain; charset=utf-8"));
    } else if item.kind == Kind.JsonBytes || item.kind == Kind.Json {
        assert(has(response, "Content-Type", "application/json"));
    } else if item.options.content_type.len == 0 {
        assert(silly::find_header(response.header_fields, response.header_bytes, "Content-Type") < 0);
    } else {
        let content_type: u8[>..] = if item.options.charset.len == 0 {
            str(item.options.content_type)
        } else {
            str(item.options.content_type, "; charset=", item.options.charset)
        };
        assert(has(response, "Content-Type", content_type));
    }
    if item.kind == Kind.Redirect {
        assert(has(response, "Location", item.payload));
    }
    if item.options.content_disposition.len > 0 {
        assert(has(response, "Content-Disposition", item.options.content_disposition));
    }
    if item.kind == Kind.Attachment {
        assert(has(response, "Content-Disposition", "attachment; filename=\"report\\\".bin\""));
    }
}

fn ordinary() {
    verify(Case {
            kind: Kind.Text,
            payload: "hello",
            ..
        }, "hello");
    verify(Case {
            kind: Kind.Empty,
            status: 204,
            ..
        }, "");
    verify(Case {
            kind: Kind.Bytes,
            payload: "a\x00b",
            ..
        }, "a\x00b");
    verify(Case {
            kind: Kind.Bytes,
            ..
        }, "");
    verify(Case {
            kind: Kind.JsonBytes,
            payload: " {\"x\":1,\"x\":2} ",
            ..
        }, " {\"x\":1,\"x\":2} ");
    verify(Case {
            kind: Kind.Json,
            ..
        }, "42");
    verify(Case {
            kind: Kind.Bytes,
            payload: "data",
            options: silly::BodyOptions {
                content_type: "text/csv",
                charset: "utf-8",
                content_disposition: "inline",
            },
            ..
        }, "data");
    verify(Case {
            kind: Kind.Attachment,
            payload: "zip\x00bytes",
            options: silly::BodyOptions {
                content_type: "application/zip",
                ..
            },
            name: "report\".bin",
            ..
        }, "zip\x00bytes");
    for status in[301, 302, 303, 307, 308] {
        verify(Case {
                kind: Kind.Redirect,
                status: status as i32,
                payload: "/next?q=a%20b",
                ..
            }, "");
    }
}

fn duplicates() {
    for kind in[Kind.Text, Kind.Empty, Kind.Bytes, Kind.Attachment, Kind.Redirect, Kind.JsonBytes, Kind.Json] {
        verify(Case {
                kind: kind,
                duplicate: true,
                ..
            }, "", silly::ResponseError.AlreadyStarted);
    }
}

fn invalid_metadata() {
    for value in["bad\r\nInjected: yes", "bad\tvalue", "bad\x00value", "bad\x7fvalue", "bad value", ""] {
        verify(Case {
                kind: Kind.Redirect,
                status: 303,
                payload: value,
                ..
            }, "", silly::ResponseError.InvalidHeader);
    }
    verify(Case {
            kind: Kind.Redirect,
            status: 304,
            payload: "/next",
            ..
        }, "", silly::ResponseError.InvalidStatus);
    for name in["", ".", "..", "dir/file", "dir\\file", "bad\r\nX: y",
        "bad\tfile", "bad\x00file", "bad\x7ffile", "\xc3\xa9"] {
        verify(Case {
                kind: Kind.Attachment,
                name: name,
                ..
            }, "", silly::ResponseError.InvalidHeader);
    }
    for value in["text/plain; charset=utf-8", "text/plain\r\nX: y", "text\t/plain", "plain", "text/", "/plain"] {
        verify(Case {
                kind: Kind.Bytes,
                options: silly::BodyOptions {
                    content_type: value,
                    ..
                },
                ..
            }, "", silly::ResponseError.InvalidHeader);
    }
    for value in["utf 8", "utf-8\t", "utf-8\r\nX: y", "\x00"] {
        verify(Case {
                kind: Kind.Bytes,
                options: silly::BodyOptions {
                    content_type: "text/plain",
                    charset: value,
                    ..
                },
                ..
            }, "", silly::ResponseError.InvalidHeader);
    }
    verify(Case {
            kind: Kind.Bytes,
            options: silly::BodyOptions {
                charset: "utf-8",
                ..
            },
            ..
        }, "", silly::ResponseError.InvalidHeader);
    for value in["inline\r\nX: y", "inline\t", "\x00", "\x7f"] {
        verify(Case {
                kind: Kind.Bytes,
                options: silly::BodyOptions {
                    content_disposition: value,
                    ..
                },
                ..
            }, "", silly::ResponseError.InvalidHeader);
    }
}

fn limits() {
    let tiny = silly::Limits {
        output_bytes_max: 2,
        ..
    };
    for kind in[Kind.Text, Kind.Bytes, Kind.Attachment, Kind.JsonBytes] {
        verify(Case {
                kind: kind,
                payload: "abc",
                ..
            }, "", silly::ResponseError.OutputLimit, tiny);
    }
    verify(Case {
            kind: Kind.Local,
            payload: "abc",
            ..
        }, "", silly::ResponseError.OutputLimit, tiny);
    verify(Case {
            kind: Kind.Bytes,
            payload: "ab",
            ..
        }, "ab", silly::ResponseError.None, tiny);
    let headers = silly::Limits {
        header_bytes_max: 20,
        ..
    };
    verify(Case {
            kind: Kind.Redirect,
            status: 303,
            payload: "/012345678901234567890",
            ..
        }, "",
        silly::ResponseError.HeaderBytesLimit, headers);
    verify(Case {
            kind: Kind.Attachment,
            ..
        }, "", silly::ResponseError.HeaderBytesLimit, headers);
    verify(Case {
            kind: Kind.Bytes,
            options: silly::BodyOptions {
                content_type: "text/plain",
                charset: "utf-8",
                ..
            },
            ..
        }, "", silly::ResponseError.HeaderBytesLimit, headers);
    verify(Case {
            kind: Kind.Text,
            ..
        }, "", silly::ResponseError.HeaderCountLimit,
        silly::Limits {
            header_count_max: 0,
            ..
        });
    for kind in[Kind.Text, Kind.Empty, Kind.Bytes, Kind.Attachment, Kind.JsonBytes] {
        verify(Case {
                kind: kind,
                status: 99,
                ..
            }, "", silly::ResponseError.InvalidStatus);
    }
}

fn exact_metadata_caps() {
    let item = Case {
        kind: Kind.Bytes,
        options: silly::BodyOptions {
            content_type: "text/plain",
            charset: "utf-8",
            ..
        },
        ..
    };
    verify(item, "", silly::ResponseError.None, silly::Limits {
            header_bytes_max: 37,
            ..
        });
    verify(item, "", silly::ResponseError.HeaderBytesLimit, silly::Limits {
            header_bytes_max: 36,
            ..
        });
    let file = Case {
        kind: Kind.Attachment,
        name: "report\".bin",
        ..
    };
    verify(file, "", silly::ResponseError.None, silly::Limits {
            header_bytes_max: 54,
            ..
        });
    verify(file, "", silly::ResponseError.HeaderBytesLimit, silly::Limits {
            header_bytes_max: 53,
            ..
        });
}

fn::main() {
    responses_test::ordinary();
    responses_test::duplicates();
    responses_test::invalid_metadata();
    responses_test::limits();
    responses_test::exact_metadata_caps();
    print("response helpers, metadata and duplicate guards passed");
}
