/* SPDX-License-Identifier: MIT */
/*
 * fpprobe4.c - can this FPMCU start an enroll session in the plain seed flow?
 *
 * Run ./fpprobe3 first (once per boot) so the seed and user context are set.
 *
 * What this does:
 *   1. Prints EC_CMD_FP_ENC_STATUS; exits if the seed is not set.
 *   2. Sets FP_MODE_ENROLL_SESSION | FP_MODE_ENROLL_IMAGE and prints the result.
 *      An error here (e.g. ec_result=4 access denied, 3 invalid param) is the
 *      useful answer: it means the plain flow is not enough.
 *   3. Polls the mode every 100 ms for ~15 s while you touch the sensor, and
 *      prints every change of mode (the firmware clears ENROLL_IMAGE once it has
 *      captured an image) together with the raw fp_stats bytes.
 *   4. Sets the mode back to 0 (idle) and prints the final status.
 *
 * It does NOT read any template or raw image out of the MCU.
 *
 * Build:  gcc -O2 -Wall -o fpprobe4 fpprobe4.c
 * Needs cros_ec_compat.h in the same directory.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#include "cros_ec_compat.h"

#define CMD_FP_MODE       0x0402
#define CMD_FP_STATS      0x0407
#define CMD_FP_ENC_STATUS 0x0409

#define FP_MODE_ENROLL_SESSION (1u << 4)
#define FP_MODE_ENROLL_IMAGE   (1u << 5)
#define FP_MODE_DONT_CHANGE    0x80000000u

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
    if (ret > 0 && in)
        memcpy(in, c->data, ret < (int)insize ? (size_t)ret : insize);
    free(c);
    return ret;
}

static double now_s(void)
{
    struct timespec t;

    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static int set_mode(int fd, uint32_t mode, uint32_t *cur, uint32_t *res)
{
    uint32_t out = 0;
    int r = ec_cmd(fd, CMD_FP_MODE, 0, &mode, 4, &out, 4, res);

    *cur = out;
    return r;
}

static void print_stats(int fd)
{
    uint8_t s[22] = {0};
    uint32_t res = 0;
    int r = ec_cmd(fd, CMD_FP_STATS, 0, NULL, 0, s, sizeof(s), &res);

    if (r > 0 && res == 0) {
        uint32_t cap, match, overall;

        memcpy(&cap, s, 4);
        memcpy(&match, s + 4, 4);
        memcpy(&overall, s + 8, 4);
        printf("    stats: capture=%uus matching=%uus overall=%uus "
               "ts_invalid=%u template_matched=%d\n",
               cap, match, overall, s[20], (int8_t)s[21]);
    } else {
        printf("    stats: ioctl=%d ec_result=%u\n", r, res);
    }
}

int main(void)
{
    uint32_t enc[2] = {0}, res = 0, cur = 0, last;
    int fd = open("/dev/cros_fp", O_RDWR), r;
    double t0;

    if (fd < 0) {
        perror("/dev/cros_fp");
        return 1;
    }

    r = ec_cmd(fd, CMD_FP_ENC_STATUS, 0, NULL, 0, enc, sizeof(enc), &res);
    printf("enc status: ioctl=%d ec_result=%u status=0x%x\n", r, res, enc[1]);
    if (r < 0 || res != 0 || !(enc[1] & 1)) {
        printf("seed is not set - run ./fpprobe3 first (once per boot).\n");
        close(fd);
        return 1;
    }

    r = set_mode(fd, FP_MODE_ENROLL_SESSION | FP_MODE_ENROLL_IMAGE, &cur, &res);
    printf("set mode ENROLL_SESSION|ENROLL_IMAGE: ioctl=%d ec_result=%u "
           "mode_now=0x%x errno=%d\n", r, res, cur, r < 0 ? errno : 0);

    if (r >= 0 && res == 0) {
        printf("\n>>> Touch and lift your finger on the sensor a few times "
               "(15 s window) <<<\n\n");
        last = cur;
        t0 = now_s();
        while (now_s() - t0 < 15.0) {
            uint32_t q = FP_MODE_DONT_CHANGE, m = 0, rs = 0;

            r = ec_cmd(fd, CMD_FP_MODE, 0, &q, 4, &m, 4, &rs);
            if (r > 0 && rs == 0 && m != last) {
                printf("[%5.2fs] mode 0x%x -> 0x%x\n", now_s() - t0, last, m);
                print_stats(fd);
                last = m;
            } else if (r < 0 || rs != 0) {
                printf("[%5.2fs] mode read failed: ioctl=%d ec_result=%u\n",
                       now_s() - t0, r, rs);
                break;
            }
            usleep(100 * 1000);
        }
    }

    r = set_mode(fd, 0, &cur, &res);
    printf("set mode idle: ioctl=%d ec_result=%u mode_now=0x%x\n", r, res, cur);

    r = ec_cmd(fd, CMD_FP_ENC_STATUS, 0, NULL, 0, enc, sizeof(enc), &res);
    printf("enc status (end): ioctl=%d ec_result=%u status=0x%x\n", r, res, enc[1]);
    close(fd);
    return 0;
}
