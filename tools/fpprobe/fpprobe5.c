/* SPDX-License-Identifier: MIT */
/* [doc:prb-enroll] */
/*
 * fpprobe5.c - run a full enrollment, driven by MKBP fingerprint events
 *
 * Run ./fpprobe3 first (once per boot) so the seed and user context are set.
 *
 * What this does:
 *   1. Exits if the seed is not set.
 *   2. Tells /dev/cros_fp to deliver only EC_MKBP_EVENT_FINGERPRINT (type 5)
 *      events (CROS_EC_DEV_IOCEVENTMASK).
 *   3. Starts an enroll session (FP_MODE_ENROLL_SESSION | FP_MODE_ENROLL_IMAGE).
 *   4. Waits for events with poll()+read(). Every raw event is hex-dumped and
 *      decoded (enroll / finger-down / finger-up / progress % / error code).
 *      After each enroll image that is not yet 100%, it re-arms the next image.
 *   5. Stops at 100%, on an enroll error that ends the session, or after 40 s
 *      without any event; then sets the mode back to idle and prints how many
 *      templates the MCU holds (fp_info.template_valid).
 *
 * It does NOT read the template out of the MCU. The enrolled template lives
 * only in the MCU's RAM and disappears on reboot.
 *
 * Build:  gcc -O2 -Wall -o fpprobe5 fpprobe5.c
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
#define CMD_FP_ENC_STATUS 0x0409

#define EC_MKBP_EVENT_FINGERPRINT 5

#define FP_MODE_ENROLL_SESSION (1u << 4)
#define FP_MODE_ENROLL_IMAGE   (1u << 5)

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

static const char *enroll_err(unsigned e)
{
    switch (e) {
    case 0: return "ok";
    case 1: return "low quality";
    case 2: return "immobile (finger did not move)";
    case 3: return "low coverage";
    case 5: return "internal error";
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
    return info[38] | (info[39] << 8);   /* uint16 template_valid at offset 38 */
}

int main(void)
{
    uint32_t enc[2] = {0}, res = 0, cur = 0;
    int fd = open("/dev/cros_fp", O_RDWR), r, done = 0;
    double t_start, t_last;

    if (fd < 0) {
        perror("/dev/cros_fp");
        return 1;
    }

    r = ec_cmd(fd, CMD_FP_ENC_STATUS, 0, NULL, 0, enc, sizeof(enc), &res);
    if (r < 0 || res != 0 || !(enc[1] & 1)) {
        printf("seed is not set - run ./fpprobe3 first (once per boot).\n");
        close(fd);
        return 1;
    }

    r = ioctl(fd, CROS_EC_DEV_IOCEVENTMASK, 1u << EC_MKBP_EVENT_FINGERPRINT);
    printf("set event mask (fingerprint only): ret=%d errno=%d\n", r, r < 0 ? errno : 0);

    r = set_mode(fd, FP_MODE_ENROLL_SESSION | FP_MODE_ENROLL_IMAGE, &cur, &res);
    printf("start enroll: ioctl=%d ec_result=%u mode_now=0x%x\n", r, res, cur);
    if (r < 0 || res != 0)
        goto out;

    printf("\n>>> Touch the sensor, lift, move your finger slightly, repeat. <<<\n"
           ">>> Stops at 100%% or after 40 s with no events.                <<<\n\n");
    t_start = t_last = now_s();

    while (!done && now_s() - t_last < 40.0) {
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

        /* Layout assumption: [event_type][data...]. Fall back to [x][type][data...]. */
        int off = -1;
        if (n >= 5 && buf[0] == EC_MKBP_EVENT_FINGERPRINT)
            off = 1;
        else if (n >= 6 && buf[1] == EC_MKBP_EVENT_FINGERPRINT)
            off = 2;
        if (off < 0) {
            printf("    (not a fingerprint event in the layout I assumed)\n");
            continue;
        }

        uint32_t ev = buf[off] | (buf[off + 1] << 8) | (buf[off + 2] << 16) |
                      ((uint32_t)buf[off + 3] << 24);
        unsigned err = ev & 0xF, progress = (ev >> 4) & 0xFF;

        printf("    fp_events=0x%08x%s%s%s%s%s", ev,
               ev & FP_EV_FINGER_DOWN ? " FINGER_DOWN" : "",
               ev & FP_EV_FINGER_UP ? " FINGER_UP" : "",
               ev & FP_EV_IMAGE_READY ? " IMAGE_READY" : "",
               ev & FP_EV_MATCH ? " MATCH" : "",
               ev & FP_EV_ENROLL ? " ENROLL" : "");
        if (ev & FP_EV_ENROLL)
            printf("  progress=%u%% err=%u (%s)", progress, err, enroll_err(err));
        printf("\n");

        if (ev & FP_EV_ENROLL) {
            if (progress >= 100) {
                printf("    enrollment reached 100%%\n");
                done = 1;
            } else {
                r = set_mode(fd, FP_MODE_ENROLL_SESSION | FP_MODE_ENROLL_IMAGE,
                             &cur, &res);
                printf("    re-arm next image: ioctl=%d ec_result=%u mode_now=0x%x\n",
                       r, res, cur);
                if (r < 0 || res != 0)
                    break;
            }
        }
    }
    if (!done)
        printf("\nstopped without reaching 100%%\n");

out:
    r = template_valid(fd);
    printf("fp_info template_valid (before idle) = %d\n", r);
    r = set_mode(fd, 0, &cur, &res);
    printf("set mode idle: ioctl=%d ec_result=%u mode_now=0x%x\n", r, res, cur);
    printf("fp_info template_valid (after idle)  = %d\n", template_valid(fd));
    close(fd);
    return 0;
}
