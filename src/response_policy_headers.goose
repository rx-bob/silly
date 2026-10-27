// CORS policy owns its response fields; generated method errors retain canonical Allow.
namespace silly;

import.cors;
import.headers;
import.response;
import.response_policy_types;

fn apply_response_policy(response: Response&, policy: ResponsePolicyState) -> ResponseError {
    let error = apply_cors(response, policy.cors);
    if error != ResponseError.None {
        return error;
    }
    if policy.method_not_allowed && response.status == 405 {
        let existing = policy_allow_fields(response, policy.allow);
        if existing < 0 {
            return fail_response(response, ResponseError.InvalidHeader);
        }
        if existing == 0 {
            return add_header(response, "Allow", policy.allow);
        }
    }
    return ResponseError.None;
}

fn policy_allow_fields(response: Response&, value: u8[:]) -> i64 {
    var count: i64 = 0;
    for index in response.header_fields.len {
        let field = header_view(response.header_fields, response.header_bytes, index);
        if header_name_equal(field.name, "Allow") {
            if field.value != value || count > 0 {
                return -1;
            }
            count += 1;
        }
    }
    return count;
}
