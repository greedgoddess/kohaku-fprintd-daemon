/* SPDX-License-Identifier: MIT */
/* [doc:prb-load] */
/*
 * fpprobe9.c - load a saved encrypted template (template0.bin) back into the FPMCU
 *
 * Prerequisite (same boot): seed set and the SAME user context that was active
 * when the template was read out (./fpprobe3 sets both; it uses a fixed test
 * user id, so repeating it restores the same context).
 *
 * What this does:
 *   1. Checks the seed is set and prints fp_info.template_valid / dirty.
 *      If the MCU already holds a template it stops, unless you pass --force
 *      (loading would just add a second copy at the next free slot).
 *   2. Reads the file; its size must equal fp_info.template_size.
 *   3. Sends it with EC_CMD_FP_TEMPLATE (version 0) in 512-byte chunks. The last
 *      chunk has FP_TEMPLATE_COMMIT (0x80000000) set in its size field, which
 *      tells the MCU the whole template has arrived and should be decrypted and
 *      loaded.
 *   4. Prints the result of the commit and the template count afterwards.
 *
 * A wrong seed or user id makes the MCU reject the template (decrypt/tag
 * failure); that is harmless and shows up as a non-zero ec_result.
 * It does not change the seed, the context or the mode.
 *
 * Build:  gcc -O2 -Wall -o fpprobe9 fpprobe9.c
 * Needs cros_ec_compat.h in the same directory.
 *
 * Usage:  ./fpprobe9 [template_file] [--force]
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>
#include "cros_ec_compat.h"

#define CMD_FP_INFO       0x0403
#define CMD_FP_TEMPLATE   0x0405
#define CMD_FP_ENC_STATUS 0x0409

#define FP_TEMPLATE_COMMIT 0x80000000u
#define CHUNK 512

struct fp_template_hdr {
    uint32_t offset;
    uint32_t size;       /* low bits: byte count; bit 31: commit */
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

static int get_info(int fd, uint32_t *tsize, uint16_t *valid, uint32_t *dirty)
{
    uint8_t b[48] = {0};
    uint32_t res = 0;
    int r = ec_cmd(fd, CMD_FP_INFO, 1, NULL, 0, b, sizeof(b), &res);

    if (r < 48 || res != 0)
        return -1;
    memcpy(tsize, b + 32, 4);
    memcpy(valid, b + 38, 2);
    memcpy(dirty, b + 40, 4);
    return 0;
}

int main(int argc, char **argv)
{
    const char *path = "template0.bin";
    int force = 0, fd, in, r;
    uint32_t tsize, dirty, enc[2] = {0}, res = 0, off;
    uint16_t valid;
    struct stat st;
    uint8_t *buf;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--force"))
            force = 1;
        else
            path = argv[i];
    }

    fd = open("/dev/cros_fp", O_RDWR);
    if (fd < 0) {
        perror("/dev/cros_fp");
        return 1;
    }

    r = ec_cmd(fd, CMD_FP_ENC_STATUS, 0, NULL, 0, enc, sizeof(enc), &res);
    if (r != 8 || res != 0 || !(enc[1] & 1)) {
        printf("seed is not set - run ./fpprobe3 first.\n");
        return 1;
    }
    if (get_info(fd, &tsize, &valid, &dirty)) {
        printf("fp_info failed\n");
        return 1;
    }
    printf("before: template_size=%u valid=%u dirty=0x%x\n", tsize, valid, dirty);
    if (valid >= 1 && !force) {
        printf("the MCU already holds %u template(s). Run ./fpprobe3 (context reset) "
               "and check again, or pass --force to load a second copy.\n", valid);
        return 1;
    }

    in = open(path, O_RDONLY);
    if (in < 0 || fstat(in, &st)) {
        perror(path);
        return 1;
    }
    if ((uint32_t)st.st_size != tsize) {
        printf("%s is %lld bytes, expected %u - refusing.\n", path,
               (long long)st.st_size, tsize);
        return 1;
    }
    buf = malloc(tsize);
    if (!buf || read(in, buf, tsize) != (ssize_t)tsize) {
        perror("read template file");
        return 1;
    }
    close(in);

    for (off = 0; off < tsize; off += CHUNK) {
        uint32_t n = tsize - off < CHUNK ? tsize - off : CHUNK;
        int last = (off + n == tsize);
        uint8_t pkt[sizeof(struct fp_template_hdr) + CHUNK];
        struct fp_template_hdr h = { off, n | (last ? FP_TEMPLATE_COMMIT : 0) };

        memcpy(pkt, &h, sizeof(h));
        memcpy(pkt + sizeof(h), buf + off, n);
        r = ec_cmd(fd, CMD_FP_TEMPLATE, 0, pkt, sizeof(h) + n, NULL, 0, &res);
        if (r < 0 || res != 0) {
            printf("chunk at offset %u%s failed: ioctl=%d ec_result=%u errno=%d\n",
                   off, last ? " (commit)" : "", r, res, r < 0 ? errno : 0);
            if (last)
                printf("commit rejected: wrong seed/user id, or a different template "
                       "format. Nothing was loaded.\n");
            free(buf);
            return 1;
        }
    }
    printf("sent %u bytes in %u chunks, commit accepted (ec_result=0)\n", tsize,
           (tsize + CHUNK - 1) / CHUNK);

    if (!get_info(fd, &tsize, &valid, &dirty))
        printf("after: valid=%u dirty=0x%x\n", valid, dirty);
    free(buf);
    close(fd);
    return 0;
}
