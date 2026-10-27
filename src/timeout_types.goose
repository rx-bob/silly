// The expired clock domain is retained in completion and error-renderer metadata.
namespace silly;

enum TimeoutKind {
    None,
    Head,
    Body,
    Idle,
    Write,
    Execution,
}
