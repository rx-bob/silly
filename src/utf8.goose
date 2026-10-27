// Shared scalar UTF-8 validation for structured text output and input.
namespace silly;

fn valid_utf8(bytes: u8[:]) -> bool {
    var at: i64 = 0;
    while at < bytes.len {
        let lead = bytes[at];
        if lead < 128 {
            at += 1;
            continue;
        }
        var width: i64 = 0;
        if lead >= 194 && lead <= 223 {
            width = 2;
        } else if lead >= 224 && lead <= 239 {
            width = 3;
        } else if lead >= 240 && lead <= 244 {
            width = 4;
        } else {
            return false;
        }
        if width > bytes.len - at {
            return false;
        }
        for offset in 1..width {
            if bytes[at + offset] < 128 || bytes[at + offset] > 191 {
                return false;
            }
        }
        let second = bytes[at + 1];
        if (lead == 224 && second < 160) || (lead == 237 && second > 159)
            || (lead == 240 && second < 144) || (lead == 244 && second > 143) {
            return false;
        }
        at += width;
    }
    return true;
}
