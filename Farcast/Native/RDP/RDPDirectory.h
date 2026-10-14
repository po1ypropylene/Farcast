#pragma once
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>

// A separate open description prevents searches from sharing seek positions.
// fdopendir takes ownership only on success; preserve errno while cleaning up.
static inline DIR *FCRDPOpenDirectory(int parent) {
    int fd = openat(parent, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0)
        return NULL;
    DIR *directory = fdopendir(fd);
    if (!directory) {
        int error = errno;
        close(fd);
        errno = error;
    }
    return directory;
}
