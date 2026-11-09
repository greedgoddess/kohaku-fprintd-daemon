/* SPDX-License-Identifier: MIT */
/* [doc:prb-hello] */
/*
 * fpprobe.c - read-only: is the fingerprint MCU answering, and what is it?
 *
 * Sends EC_CMD_HELLO, EC_CMD_GET_VERSION and EC_CMD_FP_INFO to /dev/cros_fp
 * (or the device given as the first argument) and prints the replies.
 * Changes nothing on the MCU.
 *
 * Build:  make   (or: gcc -O2 -Wall -o fpprobe fpprobe.c)
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include "cros_ec_compat.h"

#define CMD_HELLO        0x0001
#define CMD_GET_VERSION  0x0002
#define CMD_FP_INFO      0x0403

static int ec_cmd(int fd, uint32_t cmd, uint32_t ver, const void *out,
                  uint32_t outsize, void *in, uint32_t insize, uint32_t *res)
{
    size_t n = sizeof(struct cros_ec_command) + (outsize > insize ? outsize : insize);
    struct cros_ec_command *c = calloc(1, n);
    int ret;

    if (!c)
        return -1;
    c->version = ver;
    c->command = cmd;
    c->outsize = outsize;
    c->insize = insize;
    if (outsize)
        memcpy(c->data, out, outsize);
    ret = ioctl(fd, CROS_EC_DEV_IOCXCMD, c);
    *res = c->result;
    if (ret >= 0 && insize)
        memcpy(in, c->data, insize);
    free(c);
    return ret;
}

static void hexdump(const uint8_t *p, int n)
{
    for (int i = 0; i < n; i++)
        printf("%02x%s", p[i], (i % 16 == 15) ? "\n" : " ");
    if (n % 16)
        printf("\n");
}

int main(int argc, char **argv)
{
    const char *dev = argc > 1 ? argv[1] : "/dev/cros_fp";
    int fd = open(dev, O_RDWR);
    uint32_t res;

    if (fd < 0) {
        perror(dev);
        return 1;
    }

    uint32_t hin = 0xa0b0c0d0, hout = 0;
    int r = ec_cmd(fd, CMD_HELLO, 0, &hin, 4, &hout, 4, &res);
    printf("hello: ioctl=%d result=%u out=0x%08x (expect 0xa1b2c3d4)\n", r, res, hout);

    uint8_t ver[100] = {0};
    r = ec_cmd(fd, CMD_GET_VERSION, 0, NULL, 0, ver, sizeof(ver), &res);
    printf("version: ioctl=%d result=%u\n", r, res);
    if (r >= 0 && res == 0) {
        uint32_t cur;

        memcpy(&cur, ver + 96, 4);
        printf("  RO: %.32s\n  RW: %.32s\n  current image: %u (1=RO, 2=RW)\n",
               (char *)ver, (char *)ver + 32, cur);
    }

    for (uint32_t v = 1; v != (uint32_t)-1; v--) {
        uint8_t info[64] = {0};

        r = ec_cmd(fd, CMD_FP_INFO, v, NULL, 0, info, sizeof(info), &res);
        printf("fp_info v%u: ioctl=%d result=%u\n", v, r, res);
        if (r >= 0 && res == 0) {
            hexdump(info, sizeof(info));
            break;
        }
    }
    close(fd);
    return 0;
}
