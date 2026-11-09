/* SPDX-License-Identifier: MIT */
/* [doc:prb-seed] */
/*
 * fpprobe3.c - set the FPMCU encryption seed and user context, then check status
 *
 * THIS PROGRAM CHANGES MCU STATE (until the next reboot):
 *   1. Reads (or creates, mode 0600) a 32-byte seed file. Default: ./seed.bin
 *   2. Prints EC_CMD_FP_ENC_STATUS            (before)
 *   3. Sends EC_CMD_FP_SEED with that seed    (one-shot per boot)
 *   4. Prints EC_CMD_FP_ENC_STATUS            (after seed)
 *   5. Sends EC_CMD_FP_CONTEXT v1 (async) with a fixed 32-byte test user id,
 *      then polls GET_RESULT until it succeeds or times out
 *   6. Prints EC_CMD_FP_ENC_STATUS            (after context)
 *
 * It never captures an image, enrolls a finger, or handles a template.
 * Reboot to put the MCU back to its unseeded state.
 *
 * Usage:  ./fpprobe3 [seed_struct_version] [seed_file]
 *   seed_struct_version defaults to 4 (FP_TEMPLATE_FORMAT_VERSION)
 *
 * Build:  gcc -O2 -Wall -o fpprobe3 fpprobe3.c
 * Needs cros_ec_compat.h in the same directory.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/random.h>
#include <unistd.h>
#include "cros_ec_compat.h"

#define CMD_FP_CONTEXT    0x0406
#define CMD_FP_SEED       0x0408
#define CMD_FP_ENC_STATUS 0x0409

#define SEED_BYTES   32
#define USERID_BYTES 32

struct fp_seed_params {
    uint16_t struct_version;
    uint16_t reserved;
    uint8_t seed[SEED_BYTES];
};

struct fp_context_v1 {
    uint8_t action;          /* 0 = start (async), 1 = get result */
    uint8_t reserved[3];
    uint8_t userid[USERID_BYTES];
};

struct fp_enc_status {
    uint32_t valid_flags;
    uint32_t status;
};

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

static int print_enc_status(int fd, const char *label)
{
    struct fp_enc_status s = {0};
    uint32_t res = 0;
    int r = ec_cmd(fd, CMD_FP_ENC_STATUS, 0, NULL, 0, &s, sizeof(s), &res);

    if (r < 0 || res != 0) {
        printf("%-22s ioctl=%d ec_result=%u errno=%d\n", label, r, res, errno);
        return -1;
    }
    printf("%-22s valid_flags=0x%x status=0x%x  [seed_set=%u session=%u nonce=%u "
           "userid=%u challenge=%u enc_tmpl=%u]\n",
           label, s.valid_flags, s.status,
           !!(s.status & 1), !!(s.status & 2), !!(s.status & 4),
           !!(s.status & 8), !!(s.status & 16), !!(s.status & 32));
    return 0;
}

/* Read the 32-byte seed, creating a random one (mode 0600) if the file is missing. */
static int load_seed(const char *path, uint8_t seed[SEED_BYTES])
{
    int fd = open(path, O_RDONLY);

    if (fd < 0 && errno == ENOENT) {
        ssize_t got = getrandom(seed, SEED_BYTES, 0);

        if (got != SEED_BYTES) {
            perror("getrandom");
            return -1;
        }
        fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
        if (fd < 0 || write(fd, seed, SEED_BYTES) != SEED_BYTES) {
            perror(path);
            if (fd >= 0)
                close(fd);
            return -1;
        }
        close(fd);
        printf("created new random seed file %s (mode 0600)\n", path);
        return 0;
    }
    if (fd < 0) {
        perror(path);
        return -1;
    }
    if (read(fd, seed, SEED_BYTES) != SEED_BYTES) {
        fprintf(stderr, "%s: expected exactly %d bytes\n", path, SEED_BYTES);
        close(fd);
        return -1;
    }
    close(fd);
    printf("loaded seed from %s\n", path);
    return 0;
}

int main(int argc, char **argv)
{
    uint16_t seed_ver = argc > 1 ? (uint16_t)atoi(argv[1]) : 4;
    const char *seed_path = argc > 2 ? argv[2] : "seed.bin";
    struct fp_seed_params sp;
    struct fp_context_v1 cp;
    uint32_t res;
    int fd, r;

    memset(&sp, 0, sizeof(sp));
    if (load_seed(seed_path, sp.seed))
        return 1;
    sp.struct_version = seed_ver;

    fd = open("/dev/cros_fp", O_RDWR);
    if (fd < 0) {
        perror("/dev/cros_fp");
        return 1;
    }

    print_enc_status(fd, "status (before):");

    r = ec_cmd(fd, CMD_FP_SEED, 0, &sp, sizeof(sp), NULL, 0, &res);
    printf("fp_seed (struct_version=%u): ioctl=%d ec_result=%u\n", seed_ver, r, res);
    memset(&sp, 0, sizeof(sp));   /* don't leave the seed lying around in memory */
    print_enc_status(fd, "status (after seed):");

    memset(&cp, 0, sizeof(cp));
    for (int i = 0; i < USERID_BYTES; i++)
        cp.userid[i] = (uint8_t)(0xA0 + i);       /* fixed test user id */

    cp.action = 0;
    r = ec_cmd(fd, CMD_FP_CONTEXT, 1, &cp, sizeof(cp), NULL, 0, &res);
    printf("fp_context start (v1): ioctl=%d ec_result=%u\n", r, res);

    cp.action = 1;
    for (int i = 0; i < 50; i++) {
        r = ec_cmd(fd, CMD_FP_CONTEXT, 1, &cp, sizeof(cp), NULL, 0, &res);
        if (r >= 0 && res == 0) {
            printf("fp_context get_result: success after %d poll(s)\n", i + 1);
            break;
        }
        if (i == 49)
            printf("fp_context get_result: still not successful (ioctl=%d "
                   "ec_result=%u)\n", r, res);
        usleep(100 * 1000);
    }
    print_enc_status(fd, "status (after ctx):");

    close(fd);
    return 0;
}
