// Body views always remove transfer framing; content decoding is an explicit request choice.
namespace silly_client;

fn response_name_equal(left: u8[:], right: u8[:]) -> bool {
    if left.len != right.len {
        return false;
    }
    for index in left.len {
        let a = if left[index] >= 'A' && left[index] <= 'Z' {
            left[index] + 32
        } else {
            left[index]
        };
        let b = if right[index] >= 'A' && right[index] <= 'Z' {
            right[index] + 32
        } else {
            right[index]
        };
        if a != b {
            return false;
        }
    }
    return true;
}

fn decoded_response_field(name: u8[:], decoded: bool, bodyless: bool, transfer_coded: bool = false) -> bool {
    if response_name_equal(name, "Transfer-Encoding") || response_name_equal(name, "Trailer") {
        return false;
    }
    if bodyless {
        return true;
    }
    if response_name_equal(name, "Content-Length") {
        return !decoded && !transfer_coded;
    }
    return !decoded || !response_name_equal(name, "Content-Encoding");
}
