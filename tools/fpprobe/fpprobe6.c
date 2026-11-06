/* SPDX-License-Identifier: MIT */
/*
 * fpprobe6.c - try matching against the template currently held in the MCU
 *
 * Prerequisite (same boot): ./fpprobe3 then ./fpprobe5, so the seed is set and
 * one enrolled template is sitting in the MCU's RAM.
 *
 * What this does:
 *   1. Exits unless the seed is set and fp_info.template_valid >= 1.
 *   2. Subscribes to fingerprint MKBP events.
 *   3. Starts match mode (FP_MODE_MATCH | FP_MODE_MATCH_NO_TEMPLATE_UPDATE, so
 *      the stored template is not modified; falls back to plain FP_MODE_MATCH
 *      if the firmware rejects that combination).
 *   4. For each match event: prints the decoded result and fp_stats, then
 *      re-arms match mode. Stops after 8 results or 40 s without events.
 *   5. Sets the mode back to idle.
 *
 * It does NOT read the template out of the MCU.
 *
 * Build:  gcc -O2 -Wall -o fpprobe6 fpprobe6.c
 * Needs cros_ec_compat.h in the same directory.
 */
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>
#include "cros_ec_compat.h"

#ifndef CROS_EC_DEV_IOCEVENTMASK
#define CROS_EC_DEV_IOCEVENTMASK _IO(CROS_EC_DEV_IOC, 2)
#endif

#define CMD_FP_MODE       0x0402
#define CMD_FP_INFO       0x0403
#define CMD_FP_STATS      0x0407
#define CMD_FP_ENC_STATUS 0x0409

#define EC_MKBP_EVENT_FINGERPRINT 5

#define FP_MODE_MATCH                    (1u << 6)
#define FP_MODE_MATCH_NO_TEMPLATE_UPDATE (1u << 11)

#define FP_EV_ENROLL      (1u << 27)
#define FP_EV_MATCH       (1u << 28)
#define FP_EV_FINGER_DOWN (1u << 29)
#define FP_EV_FINGER_UP   (1u << 30)
#define FP_EV_IMAGE_READY (1u << 31)

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

static int set_mode(int fd, uint32_t mode, uint32_t *cur, uint32_t *res)
{
    uint32_t out = 0;
    int r = ec_cmd(fd, CMD_FP_MODE, 0, &mode, 4, &out, 4, res);

    *cur = out;
    return r;
}

static const char *match_name(unsigned e)
{
    switch (e) {
    case 0: return "NO match";
    case 1: return "MATCH";
    case 2: return "no match (low quality image)";
    case 3: return "MATCH (template updated)";
    case 4: return "no match (low coverage)";
    case 5: return "MATCH (template update failed)";
    case 6: return "no match (internal error)";
    case 7: return "no match (no templates loaded)";
    case 8: return "no match (AUTH FAIL)";
    default: return "?";
    }
}

static double now_s(void)
{
    struct timespec t;

    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static int template_valid(int fd)
{
    uint8_t info[48] = {0};
    uint32_t res = 0;
    int r = ec_cmd(fd, CMD_FP_INFO, 1, NULL, 0, info, sizeof(info), &res);

    if (r < 40 || res != 0)
        return -1;
    return info[38] | (info[39] << 8);
}

static void print_stats(int fd)
{
    uint8_t s[22] = {0};
    uint32_t res = 0, cap, match, overall;
    int r = ec_cmd(fd, CMD_FP_STATS, 0, NULL, 0, s, sizeof(s), &res);

    if (r < 22 || res != 0) {
        printf("    stats: ioctl=%d ec_result=%u\n", r, res);
        return;
    }
    memcpy(&cap, s, 4);
    memcpy(&match, s + 4, 4);
    memcpy(&overall, s + 8, 4);
    printf("    stats: capture=%uus matching=%uus overall=%uus template_matched=%d\n",
           cap, match, overall, (int8_t)s[21]);
}

int main(void)
{
    uint32_t enc[2] = {0}, res = 0, cur = 0, mode;
    int fd = open("/dev/cros_fp", O_RDWR), r, results = 0, tv;
    double t_start, t_last;

    if (fd < 0) {
        perror("/dev/cros_fp");
        return 1;
    }

    r = ec_cmd(fd, CMD_FP_ENC_STATUS, 0, NULL, 0, enc, sizeof(enc), &res);
    tv = template_valid(fd);
    if (r < 0 || res != 0 || !(enc[1] & 1) || tv < 1) {
        printf("need seed set and a template in the MCU (seed_set=%u template_valid=%d).\n"
               "run ./fpprobe3 then ./fpprobe5 first (same boot).\n",
               enc[1] & 1, tv);
        close(fd);
        return 1;
    }
    printf("templates in MCU: %d\n", tv);

    r = ioctl(fd, CROS_EC_DEV_IOCEVENTMASK, 1u << EC_MKBP_EVENT_FINGERPRINT);
    printf("set event mask: ret=%d errno=%d\n", r, r < 0 ? errno : 0);

    mode = FP_MODE_MATCH | FP_MODE_MATCH_NO_TEMPLATE_UPDATE;
    r = set_mode(fd, mode, &cur, &res);
    printf("start match (MATCH|NO_TEMPLATE_UPDATE): ioctl=%d ec_result=%u mode_now=0x%x\n",
           r, res, cur);
    if (r < 0 || res != 0) {
        mode = FP_MODE_MATCH;
        r = set_mode(fd, mode, &cur, &res);
        printf("start match (plain MATCH): ioctl=%d ec_result=%u mode_now=0x%x\n",
               r, res, cur);
        if (r < 0 || res != 0)
            goto out;
    }

    printf("\n>>> Touch the sensor with the ENROLLED finger a few times, then with a\n"
           ">>> DIFFERENT finger. Stops after 8 results or 40 s without events.\n\n");
    t_start = t_last = now_s();

    while (results < 8 && now_s() - t_last < 40.0) {
        struct pollfd p = { .fd = fd, .events = POLLIN };
        uint8_t buf[64];
        int pr = poll(&p, 1, 1000);
        ssize_t n;

        if (pr < 0) {
            perror("poll");
            break;
        }
        if (pr == 0)
            continue;
        n = read(fd, buf, sizeof(buf));
        if (n <= 0) {
            printf("read returned %zd errno=%d\n", n, errno);
            break;
        }
        t_last = now_s();

        printf("[%6.2fs] raw(%zd):", t_last - t_start, n);
        for (ssize_t i = 0; i < n; i++)
            printf(" %02x", buf[i]);
        printf("\n");

        if (n < 5 || buf[0] != EC_MKBP_EVENT_FINGERPRINT) {
            printf("    (not a fingerprint event)\n");
            continue;
        }
        uint32_t ev = buf[1] | (buf[2] << 8) | (buf[3] << 16) | ((uint32_t)buf[4] << 24);

        printf("    fp_events=0x%08x%s%s%s%s%s\n", ev,
               ev & FP_EV_FINGER_DOWN ? " FINGER_DOWN" : "",
               ev & FP_EV_FINGER_UP ? " FINGER_UP" : "",
               ev & FP_EV_IMAGE_READY ? " IMAGE_READY" : "",
               ev & FP_EV_MATCH ? " MATCH" : "",
               ev & FP_EV_ENROLL ? " ENROLL" : "");

        if (ev & FP_EV_MATCH) {
            unsigned err = ev & 0xF, idx = (ev >> 12) & 0xF;

            results++;
            printf("    result #%d: err=%u -> %s", results, err, match_name(err));
            if (err == 1 || err == 3 || err == 5)
                printf(", template index %u", idx);
            printf("\n");
            print_stats(fd);
            r = set_mode(fd, mode, &cur, &res);
            printf("    re-arm: ioctl=%d ec_result=%u mode_now=0x%x\n", r, res, cur);
            if (r < 0 || res != 0)
                break;
        }
    }

out:
    r = set_mode(fd, 0, &cur, &res);
    printf("set mode idle: ioctl=%d ec_result=%u mode_now=0x%x\n", r, res, cur);
    printf("templates in MCU (end): %d\n", template_valid(fd));
    close(fd);
    return 0;
}
