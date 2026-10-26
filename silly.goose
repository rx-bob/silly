// Core package entry point. Server and handler contracts are specified in docs/public_api.md.
namespace silly;

import.src.context;
import.src.headers;
import.src.limits;
import.src.memory_transport;
import.src.request;
import.src.response;

// Owned marker for applications with no initialization or mutable application state.
struct NoState {
}

// Owned marker for applications with no resumable stream producer.
struct NoStream {
}
