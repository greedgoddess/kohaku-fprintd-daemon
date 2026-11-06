/* SPDX-License-Identifier: MIT */
/*
 * Minimal re-declaration of the cros_ec character-device interface (the
 * struct cros_ec_command layout and the CROS_EC_DEV_IOCXCMD ioctl number), as
 * exposed by the Linux kernel's cros_ec chardev, for systems whose kernel
 * headers don't ship <linux/cros_ec_dev.h>.
 */
#ifndef CROS_EC_COMPAT_H
#define CROS_EC_COMPAT_H
#include <stdint.h>
#include <sys/ioctl.h>
struct cros_ec_command {
    uint32_t version;
    uint32_t command;
    uint32_t outsize;
    uint32_t insize;
    uint32_t result;
    uint8_t data[];
};
#define CROS_EC_DEV_IOC      0xEC
#define CROS_EC_DEV_IOCXCMD  _IOWR(CROS_EC_DEV_IOC, 0, struct cros_ec_command)
#endif
