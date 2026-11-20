#include "DPUtun.h"
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/socket.h>
#include <sys/sys_domain.h>
#include <net/if_utun.h>
#include <unistd.h>

int dp_utun_open(char *name, size_t capacity) {
    if (name == NULL || capacity == 0) {
        errno = EINVAL;
        return -1;
    }
    int fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL);
    if (fd < 0) return -1;

    struct ctl_info info = {0};
    strlcpy(info.ctl_name, UTUN_CONTROL_NAME, sizeof(info.ctl_name));
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) < 0 || ioctl(fd, CTLIOCGINFO, &info) < 0) goto failure;
    struct sockaddr_ctl addr = {
        .sc_len = sizeof(addr),
        .sc_family = AF_SYSTEM,
        .ss_sysaddr = AF_SYS_CONTROL,
        .sc_id = info.ctl_id,
        .sc_unit = 0
    };
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) goto failure;

    socklen_t size = (socklen_t)capacity;
    if (getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME, name, &size) < 0) goto failure;
    return fd;

failure:;
    int saved = errno;
    close(fd);
    errno = saved;
    return -1;
}
