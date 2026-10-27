// Resolve status/method/version semantics before any response bytes are committed.
namespace silly;

import.headers;
import.limits;
import.response;
import.response_wire_types;

fn plan_response_wire(response: Response&, options: ResponseWireOptions) -> ResponseWirePlan {
    var plan = ResponseWirePlan {
        close: options.close,
        ..
    };
    plan.error = validate_response_wire(response, options);
    if plan.error != ResponseError.None {
        return plan;
    }
    if response.status == 204 || response.status == 304 {
        if response.status == 304 {
            plan.content_length = options.representation_length;
        }
    } else if response.status == 205 {
        plan.framing = ResponseFraming.Fixed;
        plan.content_length = 0;
    } else if options.request_method == "HEAD" {
        plan.content_length = if options.representation_length >= 0 {
            options.representation_length
        } else if response.mode == ResponseBodyMode.Buffered {
            response.output.len
        } else {
            -1
        };
    } else if response.mode == ResponseBodyMode.Buffered {
        plan.framing = ResponseFraming.Fixed;
        plan.content_length = response.output.len;
        plan.body_bytes = response.output.len;
    } else if options.stream_length >= 0 {
        plan.framing = ResponseFraming.Fixed;
        plan.content_length = options.stream_length;
        plan.body_bytes = options.stream_length;
    } else {
        plan.framing = if options.http_minor == 1 {
            ResponseFraming.Chunked
        } else {
            ResponseFraming.Close
        };
        plan.body_bytes = -1;
        if plan.framing == ResponseFraming.Close {
            plan.close = true;
        }
    }
    return plan;
}

fn validate_response_wire(response: Response&, options: ResponseWireOptions) -> ResponseError {
    if response.phase != ResponsePhase.Prepared || (options.http_minor != 0 && options.http_minor != 1)
        || !valid_header_name(options.request_method) {
        return ResponseError.InvalidState;
    }
    if !valid(response.limits) || options.representation_length < - 1 || options.stream_length < - 1 {
        return ResponseError.InvalidLimits;
    }
    if response.status < 200 || response.status > 599 {
        return ResponseError.InvalidStatus;
    }
    if options.request_method == "CONNECT" && response.status < 300 {
        return ResponseError.InvalidState;
    }
    if response.output.len > response.limits.output_bytes_max {
        return ResponseError.OutputLimit;
    }
    if (response.status == 204 || response.status == 205 || response.status == 304
        || response.mode == ResponseBodyMode.Stream) && response.output.len != 0 {
        return ResponseError.InvalidState;
    }
    if options.representation_length >= 0 {
        if options.request_method != "HEAD" && response.status != 304 {
            return ResponseError.InvalidState;
        }
        if response.status == 204 || response.status == 205 {
            return ResponseError.InvalidState;
        }
        if options.request_method == "HEAD" && response.output.len != 0
            && options.representation_length != response.output.len {
            return ResponseError.InvalidState;
        }
    }
    return ResponseError.None;
}
