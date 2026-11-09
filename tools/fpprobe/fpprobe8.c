/* SPDX-License-Identifier: MIT */
/* [doc:prb-save] */
/*
 * fpprobe8.c - read template 0 out of the FPMCU (encrypted) and save it to a file
 *
 * Prerequisite (same boot): seed set (./fpprobe3) and a template in the MCU
 * (./fpprobe5). Matching with ./fpprobe6 first is fine; it will have marked the
 * template as "dirty", which is exactly what we want to see change.
 *
 * What this does:
 *   1. Checks that the seed is set and fp_info.template_valid >= 1; prints
 *      template_dirty before.
 *   2. Reads the template with EC_CMD_FP_FRAME (version 0), frame index 1 (= the
 *      first template), in 512-byte chunks, until template_size bytes are read.
 *      Stops at the first error.
 *   3. Writes the bytes to ./template0.bin (mode 0600, refuses to overwrite).
 *   4. Prints the encryption metadata header fields and the status afterwards
 *      (template_dirty, encryption status).
 *
 * The data is encrypted by the MCU with a key derived from the seed and the user
 * context, but it is still biometric data: keep the file private.
 *
 * It does not change the seed, context, mode, or the template itself.
 *
 * Build:  gcc -O2 -Wall -o fpprobe8 fpprobe8.c
 * Needs cros_ec_compat.h in the same directory.
 *
 * Usage:  ./fpprobe8 [output_file]
 */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include "cros_ec_compat.h"

#define CMD_FP_INFO       0x0403
#define CMD_FP_FRAME      0x0404
#define CMD_FP_ENC_STATUS 0x0409

#define FP_FRAME_INDEX_SHIFT 28
#define CHUNK 512

struct fp_frame_params {
    uint32_t offset;   /* (frame index << 28) | byte offset */
    uint32_t size;
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

struct info {
    uint32_t template_size;
    uint16_t template_max, template_valid;
    uint32_t template_dirty, template_version;
};

static int get_info(int fd, struct info *i)
{
    uint8_t b[48] = {0};
    uint32_t res = 0;
    int r = ec_cmd(fd, CMD_FP_INFO, 1, NULL, 0, b, sizeof(b), &res);

    if (r < 48 || res != 0)
        return -1;
    memcpy(&i->template_size, b + 32, 4);
    memcpy(&i->template_max, b + 36, 2);
    memcpy(&i->template_valid, b + 38, 2);
    memcpy(&i->template_dirty, b + 40, 4);
    memcpy(&i->template_version, b + 44, 4);
    return 0;
}

static void print_enc_status(int fd, const char *label)
{
    uint32_t enc[2] = {0}, res = 0;
    int r = ec_cmd(fd, CMD_FP_ENC_STATUS, 0, NULL, 0, enc, sizeof(enc), &res);

    if (r == 8 && res == 0)
        printf("%s enc status=0x%x (seed_set=%u enc_template_ready=%u)\n", label,
               enc[1], enc[1] & 1, !!(enc[1] & 32));
    else
        printf("%s enc status: ioctl=%d ec_result=%u\n", label, r, res);
}

int main(int argc, char **argv)
{
    const char *path = argc > 1 ? argv[1] : "template0.bin";
    int fd = open("/dev/cros_fp", O_RDWR), out, r;
    struct info inf = {0};
    uint8_t *buf;
    uint32_t res = 0, off;

    if (fd < 0) {
        perror("/dev/cros_fp");
        return 1;
    }
    if (get_info(fd, &inf)) {
        printf("fp_info failed\n");
        return 1;
    }
    printf("before: template_size=%u valid=%u dirty=0x%x format_version=%u\n",
           inf.template_size, inf.template_valid, inf.template_dirty,
           inf.template_version);
    print_enc_status(fd, "before:");
    if (inf.template_valid < 1) {
        printf("no template in the MCU - run ./fpprobe3 then ./fpprobe5 first.\n");
        return 1;
    }
    if (access(path, F_OK) == 0) {
        printf("%s already exists - move it away first (I won't overwrite it).\n", path);
        return 1;
    }

    buf = calloc(1, inf.template_size);
    if (!buf)
        return 1;

    for (off = 0; off < inf.template_size; off += CHUNK) {
        uint32_t n = inf.template_size - off < CHUNK ? inf.template_size - off : CHUNK;
        struct fp_frame_params p = { (1u << FP_FRAME_INDEX_SHIFT) | off, n };

        r = ec_cmd(fd, CMD_FP_FRAME, 0, &p, sizeof(p), buf + off, n, &res);
        if (r != (int)n || res != 0) {
            printf("chunk at offset %u failed: ioctl=%d (wanted %u) ec_result=%u errno=%d\n",
                   off, r, n, res, r < 0 ? errno : 0);
            printf("stopping; nothing written.\n");
            free(buf);
            return 1;
        }
    }
    printf("read %u bytes in %u chunks of up to %d\n", inf.template_size,
           (inf.template_size + CHUNK - 1) / CHUNK, CHUNK);

    out = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (out < 0 || write(out, buf, inf.template_size) != (ssize_t)inf.template_size) {
        perror(path);
        free(buf);
        return 1;
    }
    close(out);
    printf("wrote %s (mode 0600)\n", path);

    {
        uint16_t sv, rsv;
        unsigned zeros = 0;

        memcpy(&sv, buf, 2);
        memcpy(&rsv, buf + 2, 2);
        for (uint32_t i = 0; i < inf.template_size; i++)
            zeros += buf[i] == 0;
        printf("header: struct_version=%u reserved=%u  first 16 bytes:", sv, rsv);
        for (int i = 0; i < 16; i++)
            printf(" %02x", buf[i]);
        printf("\nzero bytes: %u of %u\n", zeros, inf.template_size);
    }

    if (!get_info(fd, &inf))
        printf("after: valid=%u dirty=0x%x\n", inf.template_valid, inf.template_dirty);
    print_enc_status(fd, "after:");
    free(buf);
    close(fd);
    return 0;
}
