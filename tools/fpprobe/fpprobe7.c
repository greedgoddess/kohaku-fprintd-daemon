/*
 * fpprobe7.c - read-only: transfer limits, FP command versions, template state
 *
 * Sends only read-only queries:
 *   - EC_CMD_GET_PROTOCOL_INFO (0x000B): max request/response packet sizes
 *   - EC_CMD_GET_CMD_VERSIONS  (0x0008): which versions of the FP commands the
 *     firmware implements (FP_MODE, FP_INFO, FP_FRAME, FP_TEMPLATE, FP_CONTEXT,
 *     FP_SEED, FP_ENC_STATUS)
 *   - EC_CMD_FP_INFO v1: template_valid / template_dirty / template_size
 *
 * It does not change any state and works with or without a seed set.
 *
 * Build:  gcc -O2 -Wall -o fpprobe7 fpprobe7.c
 * Needs cros_ec_compat.h in the same directory.
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include "cros_ec_compat.h"

#define CMD_GET_CMD_VERSIONS  0x0008
#define CMD_GET_PROTOCOL_INFO 0x000B
#define CMD_FP_MODE           0x0402
#define CMD_FP_INFO           0x0403
#define CMD_FP_FRAME          0x0404
#define CMD_FP_TEMPLATE       0x0405
#define CMD_FP_CONTEXT        0x0406
#define CMD_FP_SEED           0x0408
#define CMD_FP_ENC_STATUS     0x0409

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

static void cmd_versions(int fd, const char *name, uint16_t cmd)
{
    uint32_t mask = 0, res = 0;
    uint16_t p1 = cmd;
    uint8_t p0 = (uint8_t)(cmd & 0xff);
    int r = ec_cmd(fd, CMD_GET_CMD_VERSIONS, 1, &p1, sizeof(p1), &mask, 4, &res);

    if (r == 4 && res == 0) {
        printf("%-14s 0x%04x version mask = 0x%x\n", name, cmd, mask);
        return;
    }
    r = ec_cmd(fd, CMD_GET_CMD_VERSIONS, 0, &p0, sizeof(p0), &mask, 4, &res);
    if (r == 4 && res == 0)
        printf("%-14s 0x%04x version mask = 0x%x (via v0 query)\n", name, cmd, mask);
    else
        printf("%-14s 0x%04x query failed: ioctl=%d ec_result=%u\n", name, cmd, r, res);
}

int main(void)
{
    int fd = open("/dev/cros_fp", O_RDWR), r;
    uint32_t res = 0;
    uint8_t pi[12] = {0}, info[48] = {0};

    if (fd < 0) {
        perror("/dev/cros_fp");
        return 1;
    }

    r = ec_cmd(fd, CMD_GET_PROTOCOL_INFO, 0, NULL, 0, pi, sizeof(pi), &res);
    printf("protocol info: ioctl=%d ec_result=%u\n", r, res);
    if (r > 0 && res == 0) {
        uint32_t versions, flags;
        uint16_t max_req, max_resp;

        memcpy(&versions, pi, 4);
        memcpy(&max_req, pi + 4, 2);
        memcpy(&max_resp, pi + 6, 2);
        memcpy(&flags, pi + 8, 4);
        printf("  protocol_versions=0x%x max_request=%u max_response=%u flags=0x%x\n",
               versions, max_req, max_resp, flags);
        printf("  raw:");
        for (int i = 0; i < r; i++)
            printf(" %02x", pi[i]);
        printf("\n");
    }

    cmd_versions(fd, "FP_MODE", CMD_FP_MODE);
    cmd_versions(fd, "FP_INFO", CMD_FP_INFO);
    cmd_versions(fd, "FP_FRAME", CMD_FP_FRAME);
    cmd_versions(fd, "FP_TEMPLATE", CMD_FP_TEMPLATE);
    cmd_versions(fd, "FP_CONTEXT", CMD_FP_CONTEXT);
    cmd_versions(fd, "FP_SEED", CMD_FP_SEED);
    cmd_versions(fd, "FP_ENC_STATUS", CMD_FP_ENC_STATUS);

    r = ec_cmd(fd, CMD_FP_INFO, 1, NULL, 0, info, sizeof(info), &res);
    if (r >= 48 && res == 0) {
        uint32_t tsize, dirty, tver;
        uint16_t tmax, tvalid;

        memcpy(&tsize, info + 32, 4);
        memcpy(&tmax, info + 36, 2);
        memcpy(&tvalid, info + 38, 2);
        memcpy(&dirty, info + 40, 4);
        memcpy(&tver, info + 44, 4);
        printf("fp_info: template_size=%u max=%u valid=%u dirty=0x%x format_version=%u\n",
               tsize, tmax, tvalid, dirty, tver);
    } else {
        printf("fp_info: ioctl=%d ec_result=%u\n", r, res);
    }
    close(fd);
    return 0;
}
