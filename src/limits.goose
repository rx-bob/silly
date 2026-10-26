// Resource caps for request views and buffered response preparation.
namespace silly;

struct Limits {
    head_bytes_max: i64 = 32 * 1024,
    header_count_max: i64 = 100,
    header_bytes_max: i64 = 32 * 1024,
    body_bytes_max: i64 = 8 * 1024 * 1024,
    output_bytes_max: i64 = 8 * 1024 * 1024,
}

fn valid(limits: Limits) -> bool {
    return limits.head_bytes_max > 0
        && limits.header_count_max >= 0
        && limits.header_bytes_max >= 0
        && limits.body_bytes_max >= 0
        && limits.output_bytes_max >= 0;
}
