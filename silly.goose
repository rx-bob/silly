// Core package entry point. Server and handler contracts are specified in docs/public_api.md.
namespace silly;

// Owned marker for applications with no initialization or mutable application state.
struct NoState {
}

// Owned marker for applications with no resumable stream producer.
struct NoStream {
}
