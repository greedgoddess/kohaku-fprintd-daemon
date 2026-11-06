/* SPDX-License-Identifier: MIT */
/*
 * fpprobe2.c - read-only probe of the ChromeOS fingerprint MCU (FPMCU)
 *
 * Sends three commands via /dev/cros_fp and hex-dumps the replies:
 *   - EC_CMD_FP_MODE (0x0402) with FP_MODE_DONT_CHANGE  (report current mode)
 *   - EC_CMD_FP_STATS (0x0407)
 *   - EC_CMD_FP_ENC_STATUS (0x0409)
 *
 * It does NOT set a seed, change the mode, capture an image, or touch templates.
 *
 * Build:  gcc -O2 -Wall -o fpprobe2 fpprobe2.c
 * Needs cros_ec_compat.h (the small ioctl/struct header from the earlier step)
 * in the same directory.
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include "cros_ec_compat.h"

#define CMD_FP_MODE         0x0402
#define CMD_FP_STATS        0x0407
#define CMD_FP_ENC_STATUS   0x0409
#define FP_MODE_DONT_CHANGE 0x80000000u

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
    if (ret > 0)
        memcpy(in, c->data, ret < (int)insize ? (size_t)ret : insize);
    free(c);
    return ret;
}

static void hexdump(const uint8_t *p, int n)
{
    for (int i = 0; i < n; i++)
        printf("%02x%s", p[i], (i % 16 == 15 || i == n - 1) ? "\n" : " ");
}

static void probe(int fd, const char *name, uint32_t cmd, const void *out,
                  uint32_t outsize)
{
    uint8_t buf[128] = {0};
    uint32_t res = 0;
    int r = ec_cmd(fd, cmd, 0, out, outsize, buf, sizeof(buf), &res);

    printf("%s: ioctl=%d ec_result=%u\n", name, r, res);
    if (r > 0 && res == 0)
        hexdump(buf, r);
}

int main(void)
{
    int fd = open("/dev/cros_fp", O_RDWR);
    uint32_t dont_change = FP_MODE_DONT_CHANGE;

    if (fd < 0) {
        perror("/dev/cros_fp");
        return 1;
    }

    probe(fd, "fp_mode (get)", CMD_FP_MODE, &dont_change, 4);
    probe(fd, "fp_stats", CMD_FP_STATS, NULL, 0);
    probe(fd, "fp_enc_status", CMD_FP_ENC_STATUS, NULL, 0);
    close(fd);
    return 0;
}
