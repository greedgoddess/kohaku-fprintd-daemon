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
