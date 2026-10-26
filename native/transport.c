// Synchronous POSIX boundary. No borrowed Goose address survives a call.
#ifndef _POSIX_C_SOURCE
#define _POSIX_C_SOURCE 200809L
#endif
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>

typedef struct { uint8_t *data; int64_t len; } silly_bytes;
typedef struct { int32_t *data; int64_t len; } silly_ints;

// Low byte is the portable status, upper bytes preserve the native errno.
static int64_t silly_failure(int error) {
    int kind = 5;
    if (error == EAGAIN || error == EWOULDBLOCK) kind = 1;
    else if (error == EINTR) kind = 2;
    else if (error == EPIPE || error == ECONNRESET || error == ENOTCONN) kind = 3;
    else if (error == EINVAL || error == EBADF) kind = 4;
    return -((int64_t)error * 256 + kind);
}

static int silly_configure(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) return -1;
    flags = fcntl(fd, F_GETFD, 0);
    if (flags < 0 || fcntl(fd, F_SETFD, flags | FD_CLOEXEC) < 0) return -1;
#ifdef SO_NOSIGPIPE
    int one = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one) < 0) return -1;
#endif
    return 0;
}

static int64_t silly_discard(int fd, int error) {
    close(fd); // Never retry close: a descriptor can already have been released on EINTR.
    return silly_failure(error);
}

static int silly_address(silly_bytes address, int32_t port, struct sockaddr_storage *storage, socklen_t *length) {
    if (address.len < 1 || address.len >= INET6_ADDRSTRLEN || port < 0 || port > 65535) return -1;
    char text[INET6_ADDRSTRLEN];
    memcpy(text, address.data, (size_t)address.len);
    text[address.len] = 0;
    if (memchr(text, 0, (size_t)address.len)) return -1;
    memset(storage, 0, sizeof *storage);
    struct sockaddr_in *v4 = (struct sockaddr_in *)storage;
    struct sockaddr_in6 *v6 = (struct sockaddr_in6 *)storage;
    if (inet_pton(AF_INET, text, &v4->sin_addr) == 1) {
        v4->sin_family = AF_INET;
        v4->sin_port = htons((uint16_t)port);
        *length = sizeof *v4;
        return AF_INET;
    }
    if (inet_pton(AF_INET6, text, &v6->sin6_addr) == 1) {
        v6->sin6_family = AF_INET6;
        v6->sin6_port = htons((uint16_t)port);
        *length = sizeof *v6;
        return AF_INET6;
    }
    return -1;
}

int64_t silly_native_listen(silly_bytes address, int32_t port, int32_t backlog) {
    struct sockaddr_storage storage;
    socklen_t length;
    int family = silly_address(address, port, &storage, &length);
    if (family < 0 || backlog < 1) return silly_failure(EINVAL);
    int fd = socket(family, SOCK_STREAM, 0);
    if (fd < 0) return silly_failure(errno);
    int one = 1;
    if (silly_configure(fd) < 0 || setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one) < 0)
        return silly_discard(fd, errno);
    if (bind(fd, (struct sockaddr *)&storage, length) < 0 || listen(fd, backlog) < 0)
        return silly_discard(fd, errno);
    return fd;
}

// The high word distinguishes an owned connecting fd from an already connected fd.
int64_t silly_native_connect(silly_bytes address, int32_t port) {
    struct sockaddr_storage storage;
    socklen_t length;
    int family = silly_address(address, port, &storage, &length);
    if (family < 0) return silly_failure(EINVAL);
    int fd = socket(family, SOCK_STREAM, 0);
    if (fd < 0) return silly_failure(errno);
    if (silly_configure(fd) < 0) return silly_discard(fd, errno);
    if (connect(fd, (struct sockaddr *)&storage, length) == 0) return fd;
    if (errno == EINPROGRESS || errno == EALREADY || errno == EINTR) return ((int64_t)1 << 32) + fd;
    return silly_discard(fd, errno);
}

int64_t silly_native_finish_connect(int32_t fd) {
    int error = 0;
    socklen_t length = sizeof error;
    if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) < 0) return silly_failure(errno);
    if (error == EINPROGRESS || error == EALREADY) return silly_failure(EAGAIN);
    return error ? silly_failure(error) : 0;
}

int64_t silly_native_receive_buffer(int32_t fd, int32_t bytes) {
    if (bytes <= 0) return silly_failure(EINVAL);
    if (setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bytes, sizeof bytes) < 0) return silly_failure(errno);
    return 0;
}

int64_t silly_native_accept(int32_t listener) {
    int fd = accept(listener, NULL, NULL);
    if (fd < 0) return silly_failure(errno);
    if (silly_configure(fd) < 0) return silly_discard(fd, errno);
    return fd;
}

int64_t silly_native_close(int32_t fd) {
    if (close(fd) < 0) return silly_failure(errno);
    return 0;
}

int64_t silly_native_read(int32_t fd, silly_bytes output) {
    if (output.len <= 0) return silly_failure(EINVAL);
    ssize_t count = recv(fd, output.data, (size_t)output.len, 0);
    return count < 0 ? silly_failure(errno) : count;
}

int64_t silly_native_write(int32_t fd, silly_bytes head, silly_bytes body) {
    if (head.len < 0 || body.len < 0 || head.len > SSIZE_MAX - body.len) return silly_failure(EINVAL);
    struct iovec parts[2] = {{head.data, (size_t)head.len}, {body.data, (size_t)body.len}};
    struct msghdr message;
    memset(&message, 0, sizeof message);
    message.msg_iov = parts;
    message.msg_iovlen = 2;
    int flags = 0;
#ifdef MSG_NOSIGNAL
    flags = MSG_NOSIGNAL;
#endif
    ssize_t count = sendmsg(fd, &message, flags);
    return count < 0 ? silly_failure(errno) : count;
}

int64_t silly_native_poll(silly_ints fds, silly_ints interests, silly_ints events, int32_t timeout) {
    if (fds.len < 0 || fds.len > 1024 || interests.len != fds.len || events.len != fds.len || timeout < 0)
        return silly_failure(EINVAL);
    struct pollfd entries[1024];
    for (int64_t i = 0; i < fds.len; ++i) {
        if (interests.data[i] < 0 || (interests.data[i] & ~3)) return silly_failure(EINVAL);
        entries[i].fd = fds.data[i];
        entries[i].events = ((interests.data[i] & 1) ? POLLIN : 0) | ((interests.data[i] & 2) ? POLLOUT : 0);
        entries[i].revents = 0;
        events.data[i] = 0;
    }
    int count = poll(entries, (nfds_t)fds.len, timeout);
    if (count < 0) return silly_failure(errno);
    for (int64_t i = 0; i < fds.len; ++i) {
        short ready = entries[i].revents;
        events.data[i] = ((ready & POLLIN) ? 1 : 0) | ((ready & POLLOUT) ? 2 : 0)
            | ((ready & POLLHUP) ? 4 : 0) | ((ready & (POLLERR | POLLNVAL)) ? 8 : 0);
    }
    return count;
}

int64_t silly_native_clock(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) < 0) return silly_failure(errno);
    if (now.tv_sec < 0 || now.tv_sec > INT64_MAX / 1000) return silly_failure(EOVERFLOW);
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

int64_t silly_native_pair(silly_ints output, int32_t send_buffer) {
    if (output.len != 2 || send_buffer < 0) return silly_failure(EINVAL);
    int fds[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) < 0) return silly_failure(errno);
    int error = 0;
    if (silly_configure(fds[0]) < 0 || silly_configure(fds[1]) < 0) error = errno;
    if (!error && send_buffer > 0) {
        if (setsockopt(fds[0], SOL_SOCKET, SO_SNDBUF, &send_buffer, sizeof send_buffer) < 0
            || setsockopt(fds[1], SOL_SOCKET, SO_SNDBUF, &send_buffer, sizeof send_buffer) < 0) error = errno;
    }
    if (error) {
        close(fds[0]);
        close(fds[1]);
        return silly_failure(error);
    }
    output.data[0] = fds[0];
    output.data[1] = fds[1];
    return 0;
}

int64_t silly_native_port(int32_t fd) {
    struct sockaddr_storage storage;
    socklen_t length = sizeof storage;
    if (getsockname(fd, (struct sockaddr *)&storage, &length) < 0) return silly_failure(errno);
    if (storage.ss_family == AF_INET) return ntohs(((struct sockaddr_in *)&storage)->sin_port);
    if (storage.ss_family == AF_INET6) return ntohs(((struct sockaddr_in6 *)&storage)->sin6_port);
    return silly_failure(EINVAL);
}
