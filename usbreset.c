/* Minimal USB reset: what the goodix-fp-dump maintainer prescribes when the
 * tool stops at its first command with "Invalid message protocol".
 *
 *   gcc -O2 -o usbreset usbreset.c
 *   sudo ./usbreset /dev/bus/usb/003/002
 *
 * Same behaviour as the USBDEVFS_RESET example in
 * https://github.com/knauth/goodix-521d-explanation (public domain snippet).
 */
#include <fcntl.h>
#include <linux/usbdevice_fs.h>
#include <stdio.h>
#include <sys/ioctl.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s /dev/bus/usb/<bus>/<device>\n", argv[0]);
        return 2;
    }

    int fd = open(argv[1], O_WRONLY);
    if (fd < 0) {
        perror("open");
        return 1;
    }
    if (ioctl(fd, USBDEVFS_RESET, 0) < 0) {
        perror("USBDEVFS_RESET");
        close(fd);
        return 1;
    }
    close(fd);
    printf("reset %s\n", argv[1]);
    return 0;
}
