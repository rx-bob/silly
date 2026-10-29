// Endpoint-scoped HTML output writes directly into the bounded response owner.
namespace silly;

import.response;

struct HtmlScope {
    active: bool = true,
}

// scope pins the writer to the immediate html callback, even if response lives longer.
struct HtmlWriter<R> {
    response: R&,
    scope: HtmlScope&,
}

type EndpointWriter = HtmlWriter<Response>;

fn html<A, S, F>(ctx: Context<A, S> & , status: i32) {
    let start = begin_response(ctx.response, status);
    if start != ResponseError.None {
        fail_response(ctx.response, start);
        reject(ctx);
    }
    if add_header(ctx.response, "Content-Type", "text/html; charset=utf-8") != ResponseError.None {
        reject(ctx);
    }
    var scope = HtmlScope {
    };
    var out = EndpointWriter {
        response: ctx.response,
        scope: scope,
    };
    F(out);
    scope.active = false;
    let error = prepare_response(ctx.response);
    if error != ResponseError.None {
        fail_response(ctx.response, error);
        reject(ctx);
    }
}

// Literal markup must be trusted by the caller; no escaping or UTF-8 normalization occurs.
fn append<R>(out: HtmlWriter<R>&, trusted_markup: u8[:]) {
    if !out.scope.active {
        fail_response(out.response, ResponseError.InvalidState);
        return from silly::endpoint;
    }
    let error = append_body(out.response, trusted_markup);
    if error != ResponseError.None {
        fail_response(out.response, error);
        return from silly::endpoint;
    }
}

// HTML data/RCDATA text only. Not script, style, URL or attribute context.
fn html_text<R>(out: HtmlWriter<R>&, text: u8[:]) {
    html_escape(out, text, false);
}

// Ordinary single- or double-quoted attribute values only. Caller writes the quotes.
// Escaping does not validate URLs, event-handler JavaScript, CSS or attribute names.
fn html_attribute<R>(out: HtmlWriter<R>&, text: u8[:]) {
    html_escape(out, text, true);
}

fn html_escape<R>(out: HtmlWriter<R>&, text: u8[:], attribute: bool) {
    if !html_valid_text(text) {
        fail_response(out.response, ResponseError.Application);
        return from silly::endpoint;
    }
    var start: i64 = 0;
    for index in text.len {
        let replacement = html_entity(text[index], attribute);
        if replacement.len != 0 {
            append(out, text[start..index]);
            append(out, replacement);
            start = index + 1;
        }
    }
    append(out, text[start..]);
}

// Reject malformed UTF-8 and disallowed controls; tab, LF and CR remain text characters.
fn html_valid_text(text: u8[:]) -> bool {
    if !valid_utf8(text) {
        return false;
    }
    for byte in text {
        if (byte < 32 && byte != '\t' && byte != '\n' && byte != '\r') || byte == 127 {
            return false;
        }
    }
    return true;
}

fn html_entity(byte: u8, attribute: bool) -> const u8[:] {
    if byte == '&' {
        return "&amp;";
    }
    if byte == '<' {
        return "&lt;";
    }
    if byte == '>' {
        return "&gt;";
    }
    if attribute {
        if byte == '"' {
            return "&quot;";
        }
        if byte == '\'' {
            return "&#39;";
        }
        if byte == '\t' {
            return "&#9;";
        }
        if byte == '\n' {
            return "&#10;";
        }
        if byte == '\r' {
            return "&#13;";
        }
    }
    return "";
}
