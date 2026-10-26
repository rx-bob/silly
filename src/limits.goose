// Resource caps for request views and buffered response preparation.
namespace silly;

struct Limits {
    head_bytes_max: i64 = 32 * 1024,
    header_count_max: i64 = 100,
    header_bytes_max: i64 = 32 * 1024,
    body_bytes_max: i64 = 8 * 1024 * 1024,
    output_bytes_max: i64 = 8 * 1024 * 1024,
    request_line_bytes_max: i64 = 8192,
    header_line_bytes_max: i64 = 16384,
    header_section_bytes_max: i64 = 16384,
}

fn valid(limits: Limits) -> bool {
    return limits.head_bytes_max > 0
        && limits.header_count_max >= 0
        && limits.header_bytes_max >= 0
        && limits.body_bytes_max >= 0
        && limits.output_bytes_max >= 0
        && limits.request_line_bytes_max > 0
        && limits.header_line_bytes_max > 0
        && limits.header_section_bytes_max > 0;
}
