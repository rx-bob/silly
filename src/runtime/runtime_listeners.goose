// Several logical servers share one supervised ownership domain and one native lane registry.
namespace silly;

let RUNTIME_LISTENERS_MAX = 4;

fn valid_runtime_listeners(listeners: silly_transport::Descriptor[:], wake: silly_transport::Descriptor) -> bool {
    if listeners.len <= 0 || listeners.len > RUNTIME_LISTENERS_MAX || wake.fd < 0 {
        return false;
    }
    for index in listeners.len {
        if listeners[index].fd < 0 || listeners[index].fd == wake.fd {
            return false;
        }
        for previous in index {
            if listeners[previous].fd == listeners[index].fd {
                return false;
            }
        }
    }
    return true;
}

fn close_runtime_listeners(listeners: silly_transport::Descriptor[:]) {
    for index in listeners.len {
        let fd = listeners[index].fd;
        for later in listeners.len {
            if later > index && listeners[later].fd == fd {
                listeners[later].fd = -1;
            }
        }
        silly_transport::close(listeners[index]);
    }
}

fn close_runtime_inputs(listeners: silly_transport::Descriptor[:], wake: silly_transport::Descriptor&) {
    for socket in listeners {
        if socket.fd == wake.fd {
            wake.fd = -1;
        }
    }
    close_runtime_listeners(listeners);
    silly_transport::close(wake);
}
