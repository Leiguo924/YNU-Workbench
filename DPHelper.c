#include "DPHelper.h"
#include "DPUtun.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <net/if.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#define DP_SOCKET "/var/run/ynu-native-vpn.sock"
enum { campus_route = 4, portal_route = 8 };

struct dp_request {
    char signature[4];
    uint8_t routes;
    char address[INET_ADDRSTRLEN];
};

#define DP_EXTRA_BYTES 128

struct dp_response {
    int32_t result;
    char name[IFNAMSIZ];
};

static int make_socket(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd >= 0) {
        const int enabled = 1;
        const struct timeval timeout = { 8, 0 };
        if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 ||
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) < 0 ||
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0) {
            int saved = errno;
            close(fd);
            errno = saved;
            return -1;
        }
    }
    return fd;
}

static struct sockaddr_un socket_address(void) {
    struct sockaddr_un address = { .sun_len = sizeof(address), .sun_family = AF_UNIX };
    strlcpy(address.sun_path, DP_SOCKET, sizeof(address.sun_path));
    return address;
}

static int transfer(int fd, void *bytes, size_t length, int writing) {
    size_t done = 0;
    while (done < length) {
        ssize_t count = writing ? write(fd, (char *)bytes + done, length - done)
                                : read(fd, (char *)bytes + done, length - done);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            if (count == 0) errno = EPIPE;
            return -1;
        }
        done += (size_t)count;
    }
    return 0;
}

int dp_helper_acquire_hosts(const char *address, uint8_t routes, const char *hosts, char *name, size_t capacity) {
    if (!address || strlen(address) >= INET_ADDRSTRLEN || !name || capacity < IFNAMSIZ) {
        errno = EINVAL;
        return -1;
    }
    char extra[DP_EXTRA_BYTES] = {0};
    if (hosts && strlcpy(extra, hosts, sizeof(extra)) >= sizeof(extra)) { errno = EINVAL; return -1; }
    struct sockaddr_un peer = socket_address();
    int channel = make_socket();
    if (channel < 0) return -1;
    int tunnel = -1;
    struct dp_request request = { .signature = {1, 0x44, 0x50, 0x01}, .routes = routes };
    if (extra[0]) request.signature[3] = 2;
    strlcpy(request.address, address, sizeof(request.address));
    uid_t uid = 0;
    gid_t gid = 0;
    if (connect(channel, (struct sockaddr *)&peer, sizeof(peer)) < 0 ||
        getpeereid(channel, &uid, &gid) < 0) goto done;
    if (uid != 0) {
        errno = EACCES;
        goto done;
    }
    if (transfer(channel, &request, sizeof(request), 1) < 0 ||
        (extra[0] && transfer(channel, extra, sizeof(extra), 1) < 0)) goto done;

    struct dp_response response = {0};
    struct iovec iov = { .iov_base = &response, .iov_len = sizeof(response) };
    union { struct cmsghdr align; char bytes[CMSG_SPACE(sizeof(int))]; } ancillary = {0};
    struct msghdr message = {
        .msg_iov = &iov, .msg_iovlen = 1, .msg_control = ancillary.bytes, .msg_controllen = sizeof(ancillary)
    };
    ssize_t count = recvmsg(channel, &message, MSG_WAITALL);
    if (count < 0) goto done;
    if (count != sizeof(response) || (message.msg_flags & MSG_CTRUNC)) {
        errno = EPROTO;
        goto done;
    }
    struct cmsghdr *control = CMSG_FIRSTHDR(&message);
    if (control && control->cmsg_level == SOL_SOCKET && control->cmsg_type == SCM_RIGHTS &&
        control->cmsg_len == CMSG_LEN(sizeof(int))) {
        memcpy(&tunnel, CMSG_DATA(control), sizeof(tunnel));
    }
    if (response.result != 0 || tunnel < 0 ||
        !memchr(response.name, 0, sizeof(response.name)) ||
        fcntl(tunnel, F_SETFD, FD_CLOEXEC) < 0) {
        if (tunnel >= 0) close(tunnel);
        tunnel = -1;
        errno = response.result > 0 ? response.result : EPROTO;
        goto done;
    }
    strlcpy(name, response.name, capacity);
done:;
    int saved = errno;
    close(channel);
    errno = saved;
    return tunnel;
}

int dp_helper_acquire(const char *address, uint8_t routes, char *name, size_t capacity) {
    return dp_helper_acquire_hosts(address, routes, NULL, name, capacity);
}

#ifdef DP_HELPER_SERVER
static int configure(const char *path, char *const args[]) {
    pid_t child;
    char *const environment[] = { "PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL };
    int error = posix_spawn(&child, path, NULL, NULL, args, environment);
    if (error != 0) return error;
    int status = 0;
    pid_t result;
    do { result = waitpid(child, &status, 0); } while (result < 0 && errno == EINTR);
    return result == child && WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : EIO;
}

static int add_route(char *name, char *destination) {
    char *const args[] = { "/sbin/route", "-n", "add", "-host", destination, "-interface", name, NULL };
    return configure(args[0], args);
}

static int parse_hosts(char *buffer, char *hosts[8]) {
    char *cursor = buffer;
    int count = 0;
    while (cursor) {
        char *host = strsep(&cursor, ",");
        struct in_addr address;
        if (count == 8 || inet_pton(AF_INET, host, &address) != 1 ||
            (ntohl(address.s_addr) >> 24) != 10) return -1;
        hosts[count++] = host;
    }
    return count;
}

static void serve(int channel, uid_t authorized_uid) {
    struct dp_request request = {0};
    struct dp_response response = { .result = EACCES };
    uid_t uid;
    gid_t gid;
    int tunnel = -1;
    const char signature[] = {1, 0x44, 0x50};
    char extra[DP_EXTRA_BYTES] = {0};
    char *hosts[8];
    int host_count = 0;
    if (getpeereid(channel, &uid, &gid) == 0 && uid == authorized_uid &&
        transfer(channel, &request, sizeof(request), 0) == 0) {
        struct in_addr assigned;
        response.result = EINVAL;
        if (request.signature[3] == 2) {
            if (transfer(channel, extra, sizeof(extra), 0) < 0 || !memchr(extra, 0, sizeof(extra))) {
                host_count = -1;
            } else {
                host_count = parse_hosts(extra, hosts);
            }
        }
        if (memcmp(request.signature, signature, sizeof(signature)) == 0 &&
            (request.signature[3] == 1 || request.signature[3] == 2) &&
            host_count >= 0 && (request.routes != 0 || host_count > 0) && (request.routes & ~(campus_route | portal_route)) == 0 &&
            memchr(request.address, 0, sizeof(request.address)) &&
            inet_pton(AF_INET, request.address, &assigned) == 1) {
            uint32_t numeric = ntohl(assigned.s_addr);
            if (numeric != 0 && (numeric >> 24) != 127 && (numeric >> 28) < 14) {
                tunnel = dp_utun_open(response.name, sizeof(response.name));
                if (tunnel < 0) response.result = errno;
                else {
                    char *const args[] = { "/sbin/ifconfig", response.name, "inet",
                        request.address, request.address, "netmask", "255.255.255.255", "mtu", "1300", "up", NULL };
                    response.result = configure(args[0], args);
                    if (!response.result && (request.routes & campus_route)) {
                        char *route[] = { "/sbin/route", "-n", "add", "-net", "10.111.176.0/20",
                                                "-interface", response.name, NULL };
                        response.result = configure(route[0], route);
                        if (!response.result) {
                            route[4] = "10.141.176.0/20";
                            response.result = configure(route[0], route);
                        }
                    }
                    if (!response.result && (request.routes & portal_route)) {
                        response.result = add_route(response.name, "202.203.208.5");
                        if (!response.result)
                            response.result = add_route(response.name, "113.55.14.8");
                    }
                    for (int index = 0; !response.result && index < host_count; index++)
                        response.result = add_route(response.name, hosts[index]);
                }
            }
        }
    }
    struct iovec iov = { .iov_base = &response, .iov_len = sizeof(response) };
    union { struct cmsghdr align; char bytes[CMSG_SPACE(sizeof(int))]; } ancillary = {0};
    struct msghdr message = { .msg_iov = &iov, .msg_iovlen = 1 };
    if (tunnel >= 0 && response.result == 0) {
        message.msg_control = ancillary.bytes;
        message.msg_controllen = sizeof(ancillary);
        struct cmsghdr *control = CMSG_FIRSTHDR(&message);
        control->cmsg_level = SOL_SOCKET;
        control->cmsg_type = SCM_RIGHTS;
        control->cmsg_len = CMSG_LEN(sizeof(tunnel));
        memcpy(CMSG_DATA(control), &tunnel, sizeof(tunnel));
    }
    (void)sendmsg(channel, &message, 0);
    if (tunnel >= 0) close(tunnel);
}

int main(int argc, char **argv) {
    char *end = NULL;
    if (geteuid() != 0 || argc != 2) return 1;
    unsigned long raw = strtoul(argv[1], &end, 10);
    if (!end || *end || raw == 0 || raw > UINT32_MAX) return 1;

    struct stat existing;
    if (lstat(DP_SOCKET, &existing) == 0) {
        if (!S_ISSOCK(existing.st_mode) || existing.st_uid != (uid_t)raw || unlink(DP_SOCKET) != 0) return 1;
    } else if (errno != ENOENT) return 1;

    int listener = make_socket();
    if (listener < 0) return 1;
    struct sockaddr_un address = socket_address();
    umask(077);
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) < 0 ||
        chown(DP_SOCKET, (uid_t)raw, 0) < 0 || chmod(DP_SOCKET, 0600) < 0 ||
        listen(listener, 4) < 0) {
        perror("campus-vpn helper listener");
        return 1;
    }
    for (;;) {
        int channel = accept(listener, NULL, NULL);
        if (channel < 0) {
            if (errno == EINTR) continue;
            perror("campus-vpn helper accept");
            return 1;
        }
        const int enabled = 1;
        const struct timeval timeout = { 4, 0 };
        if (fcntl(channel, F_SETFD, FD_CLOEXEC) == 0 &&
            setsockopt(channel, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) == 0 &&
            setsockopt(channel, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) == 0) {
            serve(channel, (uid_t)raw);
        }
        close(channel);
    }
}
#endif
