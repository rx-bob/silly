// Omitted metadata stays absent; charset is a separate token, never inferred for binary data.
namespace silly;

struct BodyOptions {
    content_type: const u8[:] = "",
    charset: const u8[:] = "",
    content_disposition: const u8[:] = "",
}

// ASCII basename; quotes are escaped and path separators/control bytes reject.
struct Attachment {
    filename: const u8[:],
    content_type: const u8[:] = "application/octet-stream",
    charset: const u8[:] = "",
}
