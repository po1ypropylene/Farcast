// rsync starts this remote-shell helper. Descriptor 9 is a private datagram
// socket inherited from its parent. Hand the pipes straight to the SSH worker.
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 6 || strcmp(argv[1], "peer") || strcmp(argv[2], "farcast-rsync") || strcmp(argv[3], "--server"))
        return 127;
    char packet[16384];
    size_t used = 0;
    for (int i = 3; i < argc; i++) {
        size_t len = strlen(argv[i]) + 1;
        if (len > sizeof(packet) - used)
            return 127;
        memcpy(packet + used, argv[i], len);
        used += len;
    }
    struct iovec vec = {packet, used};
    union {
        struct cmsghdr align;
        char data[CMSG_SPACE(2 * sizeof(int))];
    } control = {0};
    struct msghdr msg = {
        .msg_iov = &vec, .msg_iovlen = 1, .msg_control = control.data, .msg_controllen = sizeof(control.data)};
    struct cmsghdr *header = CMSG_FIRSTHDR(&msg);
    header->cmsg_level = SOL_SOCKET;
    header->cmsg_type = SCM_RIGHTS;
    header->cmsg_len = CMSG_LEN(2 * sizeof(int));
    int streams[] = {STDIN_FILENO, STDOUT_FILENO};
    memcpy(CMSG_DATA(header), streams, sizeof(streams));
    if (sendmsg(9, &msg, 0) != (ssize_t)used)
        return 127;
    close(STDIN_FILENO);
    close(STDOUT_FILENO);
    uint8_t status = 127;
    return read(9, &status, 1) == 1 ? status : 127;
}
