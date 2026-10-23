// BatteryFlow least-privilege SMC helper
//
// Supports only the new charge control keys for macOS 15.8+/26+:
//   bfF0 (ui8)  mode: 00 = resume charging, 02 = limit charging
//   bfD0 (ui32) upper limit percentage (first byte is percentage)
//   bfE0 (ui32) lower limit percentage
//
// Write sequence: bfF0=00 -> bfD0=upper -> bfE0=lower -> bfF0=02
// This program must run as root; it provides no write capabilities beyond these three keys.

#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } vers_t;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } plimit_t;
typedef struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } keyinfo_t;
typedef struct { uint32_t key; vers_t vers; plimit_t pLimitData; keyinfo_t keyInfo; uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32]; } SMCKeyData_t;

static io_connect_t conn = 0;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16)
         | ((uint32_t)(uint8_t)s[2] << 8) | (uint32_t)(uint8_t)s[3];
}

static kern_return_t smc_call(SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t sz = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(conn, 2, in, sizeof(SMCKeyData_t), out, &sz);
}

static int smc_open(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return -1;
    kern_return_t kr = IOServiceOpen(service, mach_task_self_, 0, &conn);
    IOObjectRelease(service);
    return kr == KERN_SUCCESS ? 0 : -1;
}

static int smc_read(const char *key, uint32_t *type, uint32_t *size, uint8_t bytes[32]) {
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = fourcc(key); in.data8 = 9;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    uint32_t n = out.keyInfo.dataSize;
    if (n == 0 || n > 32) return -1;
    *type = out.keyInfo.dataType; *size = n;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = fourcc(key); in.data8 = 5; in.keyInfo.dataSize = n;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return -1;
    memcpy(bytes, out.bytes, n);
    return 0;
}

static int smc_write(const char *key, const uint8_t *bytes, uint32_t size) {
    SMCKeyData_t in, out;
    memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
    in.key = fourcc(key); in.data8 = 6; in.keyInfo.dataSize = size;
    memcpy(in.bytes, bytes, size);
    kern_return_t kr = smc_call(&in, &out);
    return (kr == KERN_SUCCESS && out.result == 0) ? 0 : -1;
}

static int write_verified(const char *key, const uint8_t *bytes, uint32_t size) {
    if (smc_write(key, bytes, size) != 0) return -1;
    uint32_t type, readSize; uint8_t readback[32] = {0};
    if (smc_read(key, &type, &readSize, readback) != 0) return -1;
    return (readSize == size && memcmp(readback, bytes, size) == 0) ? 0 : -1;
}

static int reset_charging(void) {
    uint8_t zero = 0x00;
    return write_verified("bfF0", &zero, 1);
}

static int set_limit(int upper, int lower) {
    if (upper < 2 || upper > 100 || lower < 2 || lower >= upper) {
        fprintf(stderr, "invalid limits: upper=%d lower=%d\n", upper, lower);
        return 2;
    }
    uint8_t modeOff = 0x00;
    uint8_t modeOn = 0x02;
    uint8_t upperBytes[4] = { (uint8_t)upper, 0, 0, 0 };
    uint8_t lowerBytes[4] = { (uint8_t)lower, 0, 0, 0 };

    if (write_verified("bfF0", &modeOff, 1) != 0
        || write_verified("bfD0", upperBytes, 4) != 0
        || write_verified("bfE0", lowerBytes, 4) != 0
        || write_verified("bfF0", &modeOn, 1) != 0) {
        reset_charging();
        fprintf(stderr, "SMC write failed (root required, or keys unavailable)\n");
        return 4;
    }
    return 0;
}

static int print_status(void) {
    const char *keys[] = {"bfF0", "bfD0", "bfE0"};
    for (int i = 0; i < 3; i++) {
        uint32_t type, size; uint8_t bytes[32] = {0};
        if (smc_read(keys[i], &type, &size, bytes) != 0) {
            printf("%s unavailable\n", keys[i]);
            continue;
        }
        printf("%s =", keys[i]);
        for (uint32_t j = 0; j < size; j++) printf(" %02x", bytes[j]);
        printf("\n");
    }
    return 0;
}

static void usage(void) {
    fprintf(stderr,
        "usage:\n"
        "  batteryflow-smc status\n"
        "  batteryflow-smc reset\n"
        "  batteryflow-smc golden-gate <upper> <lower>\n");
}

int main(int argc, char **argv) {
    if (argc < 2) { usage(); return 2; }

    if (smc_open() != 0) { fprintf(stderr, "cannot open AppleSMC\n"); return 3; }

    if (strcmp(argv[1], "status") == 0) {
        int rc = print_status();
        IOServiceClose(conn);
        return rc;
    }

    if (geteuid() != 0) {
        fprintf(stderr, "batteryflow-smc: must run as root\n");
        IOServiceClose(conn);
        return 3;
    }

    int rc = 2;
    if (strcmp(argv[1], "reset") == 0) {
        rc = reset_charging() == 0 ? 0 : 4;
        if (rc != 0) fprintf(stderr, "reset failed\n");
    } else if (strcmp(argv[1], "golden-gate") == 0 && argc == 4) {
        int upper = atoi(argv[2]);
        int lower = atoi(argv[3]);
        rc = set_limit(upper, lower);
    } else {
        usage();
    }

    IOServiceClose(conn);
    return rc;
}
