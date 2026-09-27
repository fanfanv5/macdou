/* DJI4GGuard's narrowly scoped, unprivileged USB AT helper.
 * Configuration writes require a named action and explicit confirmation.
 * Never detaches drivers, sends/deletes SMS, or logs message contents.
 * Build: clang -std=c11 -Wall -Wextra -O2 modem-helper.c \
 *   -I/opt/homebrew/opt/libusb/include/libusb-1.0 \
 *   -L/opt/homebrew/opt/libusb/lib -lusb-1.0 -o modem-helper
 */
#define _POSIX_C_SOURCE 200809L
#include <libusb.h>
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <math.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include <unistd.h>

#define FIELD 256
#define RESPONSE 131072
#define UNKNOWN INT_MIN
#define AT_INTERFACE 2
#define AT_IN 0x84
#define AT_OUT 0x03

typedef struct {
    bool present, atOK, success;
    char error[FIELD], product[FIELD], manufacturer[FIELD], model[FIELD], firmware[FIELD];
    char simState[FIELD], operatorName[FIELD], mccmnc[FIELD], technology[FIELD], band[FIELD];
    int channel, csq, registrationStatus, registered, roaming, usbnet, moduleSleep;
    double rssiDbm, rsrpDbm, rsrqDb, sinrDb;
    char queryErrors[1024];
    int supportedModes, smsUsed, smsCapacity;
    bool modeWritten, restartAccepted, smsPreservesUnread;
    char smsStorage[8], smsPdu[RESPONSE];
} Snapshot;

typedef struct {
    libusb_context *context;
    libusb_device_handle *handle;
    bool claimed;
    double deadline;
} Modem;

static volatile sig_atomic_t interrupted;

static double monotonic_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}

static void on_signal(int sig) { interrupted = sig; }
static void on_alarm(int sig) {
    (void)sig;
    /* Async-signal-safe last resort for USB APIs without timeout arguments. */
    static const char message[] = "{\"present\":false,\"atOK\":false,\"success\":false,\"error\":\"helper deadline exceeded\"}\n";
    (void)write(STDOUT_FILENO, message, sizeof(message) - 1);
    _exit(2);
}

static void copy_string(char *dst, size_t capacity, const char *src) {
    if (capacity) snprintf(dst, capacity, "%s", src ? src : "");
}

static Snapshot snapshot_empty(void) {
    Snapshot s = {0};
    s.channel = s.csq = s.registrationStatus = s.registered = s.roaming = UNKNOWN;
    s.usbnet = s.moduleSleep = UNKNOWN;
    s.smsUsed = s.smsCapacity = UNKNOWN;
    s.rssiDbm = s.rsrpDbm = s.rsrqDb = s.sinrDb = NAN;
    return s;
}

static int parse_integer(const char *text, int *out) {
    if (!text || !*text) return 0;
    char *end = NULL;
    errno = 0;
    long value = strtol(text, &end, 10);
    while (end && isspace((unsigned char)*end)) end++;
    if (errno || end == text || !end || *end || value < INT_MIN || value > INT_MAX) return 0;
    *out = (int)value;
    return 1;
}

/* Split one AT response line, preserving empty quoted fields and quoted commas. */
static size_t split_csv(const char *input, char fields[][FIELD], size_t limit) {
    size_t count = 0;
    const char *p = input;
    while (count < limit && *p && *p != '\r' && *p != '\n') {
        while (*p == ' ' || *p == '\t') p++;
        size_t n = 0;
        bool quoted = *p == '"';
        if (quoted) p++;
        while (*p && *p != '\r' && *p != '\n') {
            if ((quoted && *p == '"') || (!quoted && *p == ',')) break;
            if (n + 1 < FIELD) fields[count][n++] = *p;
            p++;
        }
        if (quoted && *p == '"') p++;
        while (n && isspace((unsigned char)fields[count][n - 1])) n--;
        fields[count][n] = '\0';
        count++;
        while (*p == ' ' || *p == '\t') p++;
        if (*p != ',') break;
        p++;
        if (!*p || *p == '\r' || *p == '\n') {
            if (count < limit) fields[count++][0] = '\0';
            break;
        }
    }
    return count;
}

static const char *response_field(const char *response, const char *prefix) {
    size_t length = strlen(prefix);
    const char *line = response;
    while (*line) {
        while (*line == '\r' || *line == '\n') line++;
        if (strncmp(line, prefix, length) == 0) {
            line += length;
            while (*line == ' ' || *line == '\t') line++;
            return line;
        }
        line += strcspn(line, "\r\n");
    }
    return NULL;
}

static void line_copy(char *dst, size_t capacity, const char *source) {
    if (!source || !capacity) return;
    size_t length = strcspn(source, "\r\n");
    while (length && isspace((unsigned char)source[length - 1])) length--;
    if (length >= capacity) length = capacity - 1;
    memcpy(dst, source, length);
    dst[length] = '\0';
}

static void identity_line(const char *response, const char *command, char *dst) {
    const char *p = response;
    while (*p) {
        while (*p == '\r' || *p == '\n') p++;
        char line[FIELD] = {0};
        line_copy(line, sizeof(line), p);
        if (*line && strcmp(line, command) && strcmp(line, "OK") && strcmp(line, "ERROR") && line[0] != '+') {
            copy_string(dst, FIELD, line);
            return;
        }
        p += strcspn(p, "\r\n");
    }
}

static size_t utf8_append(char *out, size_t used, size_t capacity, uint32_t cp) {
    unsigned char bytes[4];
    size_t n;
    if (cp < 0x80) { bytes[0] = (unsigned char)cp; n = 1; }
    else if (cp < 0x800) { bytes[0] = 0xc0 | (cp >> 6); bytes[1] = 0x80 | (cp & 63); n = 2; }
    else if (cp < 0x10000) {
        bytes[0] = 0xe0 | (cp >> 12); bytes[1] = 0x80 | ((cp >> 6) & 63); bytes[2] = 0x80 | (cp & 63); n = 3;
    } else {
        bytes[0] = 0xf0 | (cp >> 18); bytes[1] = 0x80 | ((cp >> 12) & 63);
        bytes[2] = 0x80 | ((cp >> 6) & 63); bytes[3] = 0x80 | (cp & 63); n = 4;
    }
    if (used + n >= capacity) return used;
    memcpy(out + used, bytes, n);
    out[used + n] = 0;
    return used + n;
}

static bool decode_ucs2_hex(const char *input, char *output, size_t capacity) {
    size_t n = strlen(input), used = 0;
    if (!n || n % 4) return false;
    output[0] = '\0';
    for (size_t i = 0; i < n; i += 4) {
        char hex[5];
        memcpy(hex, input + i, 4); hex[4] = 0;
        for (int j = 0; j < 4; j++) if (!isxdigit((unsigned char)hex[j])) return false;
        uint32_t cp = (uint32_t)strtoul(hex, NULL, 16);
        if (!cp || (cp >= 0xd800 && cp <= 0xdfff)) return false;
        used = utf8_append(output, used, capacity, cp);
    }
    return true;
}

static void parse_csq(Snapshot *s, const char *response) {
    const char *p = response_field(response, "+CSQ:");
    char f[2][FIELD]; int value;
    if (p && split_csv(p, f, 2) >= 1 && parse_integer(f[0], &value) && value >= 0 && value <= 31) {
        s->csq = value;
        s->rssiDbm = -113 + 2 * value;
    }
}

static void parse_qcsq(Snapshot *s, const char *response) {
    const char *p = response_field(response, "+QCSQ:");
    char f[5][FIELD]; int value;
    size_t n = p ? split_csv(p, f, 5) : 0;
    if (!n || !strcmp(f[0], "NOSERVICE")) return;
    if (n > 1 && parse_integer(f[1], &value)) {
        /* EC2x/EG2x firmware can print RSSI as a positive magnitude. */
        if (value >= 30 && value <= 150) value = -value;
        if (value >= -150 && value <= -20) s->rssiDbm = value;
    }
    if (strcmp(f[0], "LTE") || n < 5) return;
    if (parse_integer(f[2], &value) && value >= -150 && value <= -30) s->rsrpDbm = value;
    /* Qualcomm QCSQ SINR encoding, not the direct dB used by QENG.
     * Quectel clarification: https://forums.quectel.com/t/54722/9
     * Invalid placeholders must not be transformed into plausible readings. */
    if (parse_integer(f[3], &value) && value >= 0 && value <= 250) s->sinrDb = value / 5.0 - 20;
    if (parse_integer(f[4], &value) && value >= -40 && value <= 0) s->rsrqDb = value;
}

static void parse_qnwinfo(Snapshot *s, const char *response) {
    const char *p = response_field(response, "+QNWINFO:");
    char f[4][FIELD]; int value;
    size_t n = p ? split_csv(p, f, 4) : 0;
    if (!n) return;
    copy_string(s->technology, FIELD, f[0]);
    if (n > 1) copy_string(s->mccmnc, FIELD, f[1]);
    if (n > 2) copy_string(s->band, FIELD, f[2]);
    if (n > 3 && parse_integer(f[3], &value) && value >= 0) s->channel = value;
}

static void parse_qspn(Snapshot *s, const char *response) {
    const char *p = response_field(response, "+QSPN:");
    char f[5][FIELD]; int alphabet = 0;
    size_t n = p ? split_csv(p, f, 5) : 0;
    if (!n) return;
    const char *name = f[0][0] ? f[0] : n > 1 && f[1][0] ? f[1] : n > 2 ? f[2] : "";
    if (n > 3) parse_integer(f[3], &alphabet);
    if (alphabet != 1 || !decode_ucs2_hex(name, s->operatorName, FIELD)) copy_string(s->operatorName, FIELD, name);
    if (!s->mccmnc[0] && n > 4) copy_string(s->mccmnc, FIELD, f[4]);
}

static void parse_registration(Snapshot *s, const char *response, const char *prefix) {
    const char *p = response_field(response, prefix);
    char f[8][FIELD]; int value;
    size_t n = p ? split_csv(p, f, 8) : 0;
    /* Read command always returns <n>,<stat>; single-field URCs are ignored. */
    if (n < 2 || !parse_integer(f[1], &value) || value < 0 || value > 10) return;
    s->registrationStatus = value;
    s->registered = value == 1 || value == 5;
    s->roaming = value == 5;
}

static unsigned int remaining_timeout(Modem *m, unsigned int maximum) {
    double remaining = m->deadline - monotonic_ms();
    if (interrupted || remaining <= 0) return 0;
    return remaining < maximum ? (unsigned int)fmax(1, remaining) : maximum;
}

static int read_usb_product(Modem *m, libusb_device_handle *handle, uint8_t index, char *out) {
    unsigned char bytes[256];
    unsigned int timeout = remaining_timeout(m, 300);
    if (!index || !timeout) return LIBUSB_ERROR_TIMEOUT;
    int count = libusb_control_transfer(handle, LIBUSB_ENDPOINT_IN, LIBUSB_REQUEST_GET_DESCRIPTOR,
        (LIBUSB_DT_STRING << 8), 0, bytes, sizeof(bytes), timeout);
    if (count < 4 || bytes[1] != LIBUSB_DT_STRING) return count < 0 ? count : LIBUSB_ERROR_IO;
    uint16_t language = bytes[2] | ((uint16_t)bytes[3] << 8);
    timeout = remaining_timeout(m, 300);
    if (!timeout) return LIBUSB_ERROR_TIMEOUT;
    count = libusb_control_transfer(handle, LIBUSB_ENDPOINT_IN, LIBUSB_REQUEST_GET_DESCRIPTOR,
        (LIBUSB_DT_STRING << 8) | index, language, bytes, sizeof(bytes), timeout);
    if (count < 2 || bytes[1] != LIBUSB_DT_STRING) return count < 0 ? count : LIBUSB_ERROR_IO;
    if (bytes[0] < count) count = bytes[0];
    size_t used = 0; out[0] = 0;
    for (int i = 2; i + 1 < count; i += 2) {
        uint32_t cp = bytes[i] | ((uint32_t)bytes[i + 1] << 8);
        if (cp >= 0xd800 && cp <= 0xdfff) cp = 0xfffd;
        if (cp) used = utf8_append(out, used, FIELD, cp);
    }
    return 0;
}

static bool contains_casefold(const char *text, const char *needle) {
    size_t n = strlen(needle);
    for (; *text; text++) if (!strncasecmp(text, needle, n)) return true;
    return false;
}

static bool product_allowed(const char *product) {
    return contains_casefold(product, "QDC507") || contains_casefold(product, "EG25") || contains_casefold(product, "Baiwang");
}

static bool open_modem(Modem *m, Snapshot *s) {
    int rc = libusb_init(&m->context);
    if (rc < 0) { snprintf(s->error, FIELD, "USB init: %s", libusb_error_name(rc)); return false; }
    libusb_device **list = NULL;
    ssize_t count = libusb_get_device_list(m->context, &list);
    if (count < 0) { copy_string(s->error, FIELD, "USB enumeration failed"); return false; }
    int matches = 0, candidateErrors = 0;
    for (ssize_t i = 0; i < count && remaining_timeout(m, 1); i++) {
        struct libusb_device_descriptor d;
        if (libusb_get_device_descriptor(list[i], &d)) continue;
        if (!((d.idVendor == 0x2c7c && d.idProduct == 0x0125) || (d.idVendor == 0x2ca3 && d.idProduct == 0x4006))) continue;
        libusb_device_handle *handle = NULL;
        rc = libusb_open(list[i], &handle);
        if (rc < 0) { candidateErrors++; snprintf(s->error, FIELD, "USB open: %s", libusb_error_name(rc)); continue; }
        char product[FIELD];
        rc = read_usb_product(m, handle, d.iProduct, product);
        if (rc < 0) {
            candidateErrors++;
            snprintf(s->error, FIELD, "USB product verification: %s", libusb_error_name(rc));
            libusb_close(handle); continue;
        }
        if (!product_allowed(product)) { libusb_close(handle); continue; }
        matches++;
        if (matches == 1) { m->handle = handle; copy_string(s->product, FIELD, product); }
        else libusb_close(handle);
    }
    libusb_free_device_list(list, 1);
    s->present = matches > 0;
    if (matches != 1 || candidateErrors || !remaining_timeout(m, 1)) {
        if (matches > 1) copy_string(s->error, FIELD, "Multiple supported modems; refusing ambiguous target");
        else if (!remaining_timeout(m, 1)) copy_string(s->error, FIELD, "USB enumeration interrupted or timed out");
        else if (!matches && !candidateErrors) copy_string(s->error, FIELD, "Supported QDC507/EG25 modem not found");
        return false;
    }
    s->error[0] = 0;
    return true;
}

static bool claim_at(Modem *m, Snapshot *s) {
    struct libusb_config_descriptor *config = NULL;
    int rc = libusb_get_active_config_descriptor(libusb_get_device(m->handle), &config);
    if (rc < 0) { snprintf(s->error, FIELD, "Active USB configuration: %s", libusb_error_name(rc)); return false; }
    bool safe = false;
    for (int i = 0; i < config->bNumInterfaces; i++) {
        for (int j = 0; j < config->interface[i].num_altsetting; j++) {
            const struct libusb_interface_descriptor *d = &config->interface[i].altsetting[j];
            if (d->bInterfaceNumber != AT_INTERFACE || d->bAlternateSetting != 0 || d->bInterfaceClass != 0xff) continue;
            int inputs = 0, outputs = 0, otherBulk = 0;
            for (int k = 0; k < d->bNumEndpoints; k++) {
                const struct libusb_endpoint_descriptor *e = &d->endpoint[k];
                if ((e->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) != LIBUSB_TRANSFER_TYPE_BULK) continue;
                if (e->bEndpointAddress == AT_IN) inputs++;
                else if (e->bEndpointAddress == AT_OUT) outputs++;
                else otherBulk++;
            }
            safe = inputs == 1 && outputs == 1 && otherBulk == 0;
        }
    }
    libusb_free_config_descriptor(config);
    if (!safe) { copy_string(s->error, FIELD, "Known vendor AT interface 2 / endpoints 03,84 unavailable; refusing other ports"); return false; }
    rc = libusb_kernel_driver_active(m->handle, AT_INTERFACE);
    if (rc == 1) { copy_string(s->error, FIELD, "AT interface is owned by a kernel driver; will not detach it"); return false; }
    if (rc < 0 && rc != LIBUSB_ERROR_NOT_SUPPORTED) {
        snprintf(s->error, FIELD, "AT interface driver check: %s", libusb_error_name(rc)); return false;
    }
    rc = libusb_claim_interface(m->handle, AT_INTERFACE);
    if (rc < 0) { snprintf(s->error, FIELD, "AT interface claim: %s", libusb_error_name(rc)); return false; }
    m->claimed = true;
    /* GET_INTERFACE is read-only. Never select an alternate setting ourselves. */
    unsigned char alternate = 255;
    unsigned int timeout = remaining_timeout(m, 250);
    rc = timeout ? libusb_control_transfer(m->handle, LIBUSB_ENDPOINT_IN | LIBUSB_RECIPIENT_INTERFACE,
        LIBUSB_REQUEST_GET_INTERFACE, 0, AT_INTERFACE, &alternate, 1, timeout) : LIBUSB_ERROR_TIMEOUT;
    if (rc != 1 || alternate != 0) {
        copy_string(s->error, FIELD, "Cannot verify the active AT alternate setting is zero"); return false;
    }
    return true;
}

/* 1 = OK, 0 = modem ERROR, -1 = timeout/transport (stop subsequent commands). */
static int terminal_result(const char *response) {
    const char *p = response;
    while (*p) {
        while (*p == '\r' || *p == '\n') p++;
        size_t n = strcspn(p, "\r\n");
        if (!p[n]) break; /* Only complete lines can terminate a response. */
        if (n == 2 && !strncmp(p, "OK", 2)) return 1;
        if ((n == 5 && !strncmp(p, "ERROR", 5)) || (n >= 11 && !strncmp(p, "+CME ERROR:", 11)) ||
            (n >= 11 && !strncmp(p, "+CMS ERROR:", 11))) return 0;
        p += n;
    }
    return -2;
}

static int at_query(Modem *m, const char *command, char *response, char *error, unsigned int budget) {
    response[0] = 0; error[0] = 0;
    double end = fmin(m->deadline, monotonic_ms() + budget);
    char wire[128];
    int wireLength = snprintf(wire, sizeof(wire), "%s\r", command);
    if (wireLength <= 0 || wireLength >= (int)sizeof(wire)) { copy_string(error, FIELD, "invalid command length"); return -1; }
    unsigned int timeout = remaining_timeout(m, 250);
    if (!timeout) { copy_string(error, FIELD, "interrupted or deadline exceeded"); return -1; }
    int written = 0;
    int rc = libusb_bulk_transfer(m->handle, AT_OUT, (unsigned char *)wire, wireLength, &written, timeout);
    if (rc < 0 || written != wireLength) {
        snprintf(error, FIELD, "USB AT write: %s", libusb_error_name(rc < 0 ? rc : LIBUSB_ERROR_IO)); return -1;
    }
    size_t used = 0;
    while (!interrupted && monotonic_ms() < end) {
        unsigned char chunk[512]; int received = 0;
        timeout = remaining_timeout(m, 100);
        if (!timeout) break;
        double left = end - monotonic_ms();
        if (left < timeout) timeout = (unsigned int)fmax(1, left);
        rc = libusb_bulk_transfer(m->handle, AT_IN, chunk, sizeof(chunk), &received, timeout);
        if (received > 0) {
            if (used + (size_t)received >= RESPONSE) { copy_string(error, FIELD, "AT response exceeded safe size"); return -1; }
            memcpy(response + used, chunk, (size_t)received); used += (size_t)received; response[used] = 0;
            int terminal = terminal_result(response);
            if (terminal != -2) {
                if (!terminal) {
                    const char *reason = response_field(response, "+CME ERROR:");
                    if (!reason) reason = response_field(response, "+CMS ERROR:");
                    if (reason) line_copy(error, FIELD, reason); else copy_string(error, FIELD, "modem returned ERROR");
                }
                return terminal;
            }
        }
        if (rc < 0 && rc != LIBUSB_ERROR_TIMEOUT) {
            snprintf(error, FIELD, "USB AT read: %s", libusb_error_name(rc)); return -1;
        }
    }
    copy_string(error, FIELD, interrupted ? "interrupted" : "AT response timed out");
    return -1;
}

static bool drain_input(Modem *m, Snapshot *s) {
    double end = monotonic_ms() + 200;
    while (!interrupted && monotonic_ms() < end) {
        unsigned char buffer[512]; int received = 0;
        unsigned int timeout = remaining_timeout(m, 25);
        if (!timeout) break;
        int rc = libusb_bulk_transfer(m->handle, AT_IN, buffer, sizeof(buffer), &received, timeout);
        if (rc == LIBUSB_ERROR_TIMEOUT && !received) return true;
        if (rc < 0 && rc != LIBUSB_ERROR_TIMEOUT) {
            snprintf(s->error, FIELD, "AT input synchronization: %s", libusb_error_name(rc)); return false;
        }
    }
    copy_string(s->error, FIELD, "AT input remained busy; refusing unsynchronized commands");
    return false;
}

static void append_query_error(Snapshot *s, const char *command, const char *error) {
    size_t used = strlen(s->queryErrors);
    snprintf(s->queryErrors + used, sizeof(s->queryErrors) - used, "%s%s: %s", used ? "; " : "", command, error);
}

static void collect_snapshot(Modem *m, Snapshot *s) {
    static const char *commands[] = {"AT+CSQ", "AT+QCSQ", "AT+QNWINFO", "AT+QSPN", "AT+CPIN?", "AT+CEREG?",
        "AT+CGREG?", "AT+CGMI", "AT+CGMM", "AT+CGMR", "AT+QCFG=\"usbnet\"", "AT+QSCLK?"};
    char response[RESPONSE], error[FIELD];
    for (size_t i = 0; i < sizeof(commands) / sizeof(commands[0]); i++) {
        const char *command = commands[i];
        if (i == 6 && s->registered != UNKNOWN) continue;
        int rc = at_query(m, command, response, error, 900);
        if (rc != 1) {
            append_query_error(s, command, error);
            if (rc < 0) { snprintf(s->error, FIELD, "%s: %s", command, error); break; }
            continue;
        }
        const char *p; int value;
        switch (i) {
            case 0: parse_csq(s, response); break;
            case 1: parse_qcsq(s, response); break;
            case 2: parse_qnwinfo(s, response); break;
            case 3: parse_qspn(s, response); break;
            case 4: p = response_field(response, "+CPIN:"); if (p) line_copy(s->simState, FIELD, p); break;
            case 5: parse_registration(s, response, "+CEREG:"); break;
            case 6: parse_registration(s, response, "+CGREG:"); break;
            case 7: identity_line(response, command, s->manufacturer); break;
            case 8: identity_line(response, command, s->model); break;
            case 9: identity_line(response, command, s->firmware); break;
            case 10: {
                char f[2][FIELD]; p = response_field(response, "+QCFG:");
                if (p && split_csv(p, f, 2) == 2 && !strcmp(f[0], "usbnet") && parse_integer(f[1], &value)) s->usbnet = value;
                break;
            }
            case 11: {
                char line[FIELD]; p = response_field(response, "+QSCLK:");
                if (p) { line_copy(line, FIELD, p); if (parse_integer(line, &value)) s->moduleSleep = value; }
                break;
            }
        }
    }
    s->success = s->atOK && !s->error[0];
}

/* Preserve valid UTF-8 and replace invalid modem bytes, never emit malformed JSON. */
static void json_string(const char *value) {
    if (!value || !*value) { fputs("null", stdout); return; }
    putchar('"');
    const unsigned char *p = (const unsigned char *)value;
    while (*p) {
        if (*p == '"' || *p == '\\') { putchar('\\'); putchar(*p++); }
        else if (*p < 0x20) { printf("\\u%04x", *p++); }
        else if (*p < 0x80) putchar(*p++);
        else {
            int n = *p >= 0xc2 && *p <= 0xdf ? 2 : *p >= 0xe0 && *p <= 0xef ? 3 : *p >= 0xf0 && *p <= 0xf4 ? 4 : 0;
            bool valid = n > 0;
            for (int i = 1; valid && i < n; i++) if (!p[i] || (p[i] & 0xc0) != 0x80) valid = false;
            if (valid && ((p[0] == 0xe0 && p[1] < 0xa0) || (p[0] == 0xed && p[1] >= 0xa0) ||
                (p[0] == 0xf0 && p[1] < 0x90) || (p[0] == 0xf4 && p[1] >= 0x90))) valid = false;
            if (valid) { fwrite(p, 1, (size_t)n, stdout); p += n; }
            else { fputs("\\ufffd", stdout); p++; }
        }
    }
    putchar('"');
}

static void json_int(int value) { if (value == UNKNOWN) fputs("null", stdout); else printf("%d", value); }
static void json_double(double value) { if (!isfinite(value)) fputs("null", stdout); else printf("%.1f", value); }
static void json_boolean(int value) { if (value == UNKNOWN) fputs("null", stdout); else fputs(value ? "true" : "false", stdout); }

#ifndef FEATURE_QUERY
#define FEATURE_QUERY at_query
#endif

static bool storage_allowed(const char *value) {
    return !strcmp(value, "ME") || !strcmp(value, "SM") || !strcmp(value, "MT") || !strcmp(value, "SR");
}

static int usbnet_value(const char *response) {
    const char *p = response_field(response, "+QCFG:");
    char f[2][FIELD]; int value;
    return p && split_csv(p, f, 2) == 2 && !strcmp(f[0], "usbnet") &&
        parse_integer(f[1], &value) && value >= 0 && value <= 3 ? value : UNKNOWN;
}

static int mode_mask(const char *response) {
    /* Only enable the exact range verified on QDC507/EG25 firmware. */
    const char *p = response;
    while ((p = strstr(p, "+QCFG:"))) {
        char line[FIELD], compact[FIELD]; line_copy(line, FIELD, p); size_t j = 0;
        for (size_t i = 0; line[i]; i++) if (!isspace((unsigned char)line[i])) compact[j++] = line[i];
        compact[j] = 0;
        if (!strcmp(compact, "+QCFG:\"usbnet\",<0-3>") || !strcmp(compact, "+QCFG:\"usbnet\",(0-3)")) return 15;
        p++;
    }
    return 0;
}

static void mode_info(Modem *m, Snapshot *s) {
    char response[RESPONSE], error[FIELD];
    if (FEATURE_QUERY(m, "AT+QCFG=\"usbnet\"", response, error, 1500) != 1 || (s->usbnet = usbnet_value(response)) == UNKNOWN) {
        copy_string(s->error, FIELD, "Cannot verify current USB network mode"); return;
    }
    if (FEATURE_QUERY(m, "AT+QCFG=?", response, error, 2500) != 1) { copy_string(s->error, FIELD, "Cannot verify supported USB modes"); return; }
    s->supportedModes = mode_mask(response); s->success = true;
}

static void switch_mode(Modem *m, Snapshot *s, int target, int expected) {
    mode_info(m, s);
    if (!s->success) return;
    s->success = false;
    if (s->usbnet != expected || !(s->supportedModes & (1 << target))) {
        copy_string(s->error, FIELD, "Current mode changed or requested mode is not advertised; refresh first"); return;
    }
    if (target == expected) { s->success = true; return; }
    char command[64], response[RESPONSE], error[FIELD];
    snprintf(command, sizeof(command), "AT+QCFG=\"usbnet\",%d", target);
    if (FEATURE_QUERY(m, command, response, error, 2500) != 1) {
        copy_string(s->error, FIELD, "Mode write not confirmed; query current mode before any retry"); return;
    }
    s->modeWritten = true;
    if (FEATURE_QUERY(m, "AT+QCFG=\"usbnet\"", response, error, 1500) != 1 || (s->usbnet = usbnet_value(response)) != target) {
        copy_string(s->error, FIELD, "Mode command accepted but readback not confirmed; restart was NOT requested"); return;
    }
    s->restartAccepted = FEATURE_QUERY(m, "AT+CFUN=1,1", response, error, 3000) == 1;
    s->success = s->restartAccepted;
    if (!s->success) copy_string(s->error, FIELD, "Mode saved; restart acknowledgement unknown. Do not repeat the mode write");
}

static void read_sms(Modem *m, Snapshot *s, const char *storage, bool allow_mark_read) {
    char response[RESPONSE], error[FIELD], command[64], previous[FIELD] = "";
    int format = UNKNOWN; bool changed_format = false, changed_store = false, synchronized = true;
    if (FEATURE_QUERY(m, "AT+CMGF?", response, error, 1200) != 1) goto failed;
    const char *p = response_field(response, "+CMGF:"); char line[FIELD];
    if (!p) goto failed;
    line_copy(line, FIELD, p); if (!parse_integer(line, &format) || (format != 0 && format != 1)) goto failed;
    if (FEATURE_QUERY(m, "AT+CPMS?", response, error, 1200) != 1) goto failed;
    char fields[9][FIELD]; p = response_field(response, "+CPMS:");
    if (!p || split_csv(p, fields, 9) != 9 || !storage_allowed(fields[0])) goto failed;
    copy_string(previous, FIELD, fields[0]);
    if (strcmp(storage, previous)) {
        snprintf(command, sizeof(command), "AT+CPMS=\"%s\"", storage);
        changed_store = true;
        if (FEATURE_QUERY(m, command, response, error, 2000) != 1) goto failed;
    }
    if (FEATURE_QUERY(m, "AT+CPMS?", response, error, 1200) != 1) goto failed;
    p = response_field(response, "+CPMS:");
    if (!p || split_csv(p, fields, 9) != 9 || strcmp(fields[0], storage) ||
        !parse_integer(fields[1], &s->smsUsed) || !parse_integer(fields[2], &s->smsCapacity)) goto failed;
    copy_string(s->smsStorage, sizeof(s->smsStorage), storage);
    if (format != 0) {
        changed_format = true;
        if (FEATURE_QUERY(m, "AT+CMGF=0", response, error, 1200) != 1) goto failed;
    }
    int rc = FEATURE_QUERY(m, "AT+CMGL=4,1", response, error, 6500);
    s->smsPreservesUnread = rc == 1;
    if (rc == 0 && allow_mark_read) rc = FEATURE_QUERY(m, "AT+CMGL=4", response, error, 6500);
    if (rc == 0 && !allow_mark_read) { copy_string(s->error, FIELD, "read_requires_marking"); goto restore; }
    if (rc != 1) { synchronized = rc == 0; goto failed; }
    copy_string(s->smsPdu, sizeof(s->smsPdu), response); s->success = true;
    goto restore;
failed:
    copy_string(s->error, FIELD, "SMS read failed; check SIM, storage and AT interface");
    synchronized = false;
restore:
    if (changed_format || changed_store) {
        /* Cleanup also runs on SIGTERM. It never holds a sleep assertion. */
        sig_atomic_t saved_signal = interrupted; interrupted = 0;
        m->deadline = monotonic_ms() + 3000; alarm(4);
        if (!synchronized) { Snapshot cleanup = snapshot_empty(); synchronized = drain_input(m, &cleanup); }
        bool restored = synchronized;
        if (restored && changed_format) {
            snprintf(command, sizeof(command), "AT+CMGF=%d", format);
            restored = FEATURE_QUERY(m, command, response, error, 1200) == 1;
        }
        if (restored && changed_store) {
            snprintf(command, sizeof(command), "AT+CPMS=\"%s\"", previous);
            restored = FEATURE_QUERY(m, command, response, error, 1200) == 1;
        }
        if (!restored) { s->success = false; s->smsPdu[0] = 0; copy_string(s->error, FIELD, "SMS settings restoration not confirmed; refresh module before retrying"); }
        interrupted = saved_signal;
    }
}

static void print_snapshot(const Snapshot *s, const char *action) {
    printf("{\"present\":%s,\"atOK\":%s,\"success\":%s,\"action\":", s->present ? "true" : "false", s->atOK ? "true" : "false", s->success ? "true" : "false");
    json_string(action);
#define STRING_FIELD(name) fputs(",\"" #name "\":", stdout); json_string(s->name)
#define INT_FIELD(name) fputs(",\"" #name "\":", stdout); json_int(s->name)
#define DOUBLE_FIELD(name) fputs(",\"" #name "\":", stdout); json_double(s->name)
#define BOOL_FIELD(name) fputs(",\"" #name "\":", stdout); json_boolean(s->name)
    STRING_FIELD(error); STRING_FIELD(product); STRING_FIELD(manufacturer); STRING_FIELD(model); STRING_FIELD(firmware);
    STRING_FIELD(simState); STRING_FIELD(operatorName); STRING_FIELD(mccmnc); STRING_FIELD(technology); STRING_FIELD(band);
    INT_FIELD(channel); INT_FIELD(csq); DOUBLE_FIELD(rssiDbm); DOUBLE_FIELD(rsrpDbm); DOUBLE_FIELD(rsrqDb); DOUBLE_FIELD(sinrDb);
    INT_FIELD(registrationStatus); BOOL_FIELD(registered); BOOL_FIELD(roaming); INT_FIELD(usbnet); INT_FIELD(moduleSleep);
    STRING_FIELD(queryErrors);
    INT_FIELD(supportedModes); BOOL_FIELD(modeWritten); BOOL_FIELD(restartAccepted);
    INT_FIELD(smsUsed); INT_FIELD(smsCapacity); BOOL_FIELD(smsPreservesUnread);
    STRING_FIELD(smsStorage); STRING_FIELD(smsPdu);
    fputs("}\n", stdout);
#undef STRING_FIELD
#undef INT_FIELD
#undef DOUBLE_FIELD
#undef BOOL_FIELD
}

static int self_test(void) {
    int failures = 0, checks = 0;
#define CHECK(expr) do { checks++; if (!(expr)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #expr); failures++; } } while (0)
    Snapshot s = snapshot_empty();
    parse_csq(&s, "AT+CSQ\r\r\n+CSQ: 24,99\r\n\r\nOK\r\n");
    CHECK(s.csq == 24 && s.rssiDbm == -65);
    s = snapshot_empty(); parse_csq(&s, "+CSQ: 99,99\r\nOK\r\n");
    CHECK(s.csq == UNKNOWN && isnan(s.rssiDbm));
    s = snapshot_empty(); parse_qcsq(&s, "+QCSQ: \"LTE\",57,-84,192,-13\r\nOK\r\n");
    CHECK(s.rssiDbm == -57 && s.rsrpDbm == -84 && fabs(s.sinrDb - 18.4) < 0.01 && s.rsrqDb == -13);
    s = snapshot_empty(); parse_qcsq(&s, "+QCSQ: \"LTE\",0,-32768,255,99\r\n");
    CHECK(isnan(s.rssiDbm) && isnan(s.rsrpDbm) && isnan(s.sinrDb) && isnan(s.rsrqDb));
    s = snapshot_empty(); parse_qcsq(&s, "+QCSQ: \"LTE\",-75,-95,0,-10\r\n");
    CHECK(s.rssiDbm == -75 && s.sinrDb == -20);
    s = snapshot_empty(); parse_qcsq(&s, "+QCSQ: \"LTE\",-75,-95,250,-10\r\n");
    CHECK(s.sinrDb == 30);
    s = snapshot_empty(); parse_qcsq(&s, "+QCSQ: \"NOSERVICE\"\r\n"); CHECK(isnan(s.rssiDbm));
    s = snapshot_empty(); parse_qnwinfo(&s, "+QNWINFO: \"FDD LTE\",\"46001\",\"LTE BAND 3\",1650\r\n");
    CHECK(!strcmp(s.technology, "FDD LTE") && !strcmp(s.mccmnc, "46001") && s.channel == 1650);
    parse_qspn(&s, "+QSPN: \"CHN,UNICOM\",\"UNICOM\",\"\",0,\"46001\"\r\n");
    CHECK(!strcmp(s.operatorName, "CHN,UNICOM"));
    parse_qspn(&s, "+QSPN: \"4E2D56FD8054901A\",\"\",\"\",1,\"46001\"\r\n");
    CHECK(!strcmp(s.operatorName, "中国联通"));
    parse_registration(&s, "+CEREG: 0,5\r\n", "+CEREG:"); CHECK(s.registered == 1 && s.roaming == 1);
    parse_registration(&s, "+CEREG: 2,2,\"ABCD\",\"123\",7\r\n", "+CEREG:"); CHECK(s.registered == 0 && s.roaming == 0);
    s = snapshot_empty(); parse_registration(&s, "+CEREG: 5\r\n", "+CEREG:"); CHECK(s.registered == UNKNOWN);
    CHECK(terminal_result("\r\nOK\r\n") == 1);
    CHECK(terminal_result("\r\nNOK\r\n") == -2);
    CHECK(terminal_result("\r\nOK") == -2);
    CHECK(terminal_result("\r\n+CME ERROR: 10\r\n") == 0);
    CHECK(product_allowed("EG25G-QDC507") && product_allowed("BAIWANG 4G") && !product_allowed("USB ADB"));
    int value; CHECK(!parse_integer("999999999999999", &value) && !parse_integer("1oops", &value));
    char id[FIELD] = {0}; identity_line("AT+CGMM\r\n\r\nEG25\r\nOK\r\n", "AT+CGMM", id); CHECK(!strcmp(id, "EG25"));
    CHECK(usbnet_value("+QCFG: \"usbnet\",1\r\nOK\r\n") == 1);
    CHECK(usbnet_value("+QCFG: \"usbnet\",9\r\n") == UNKNOWN);
    CHECK(mode_mask("+QCFG: \"usbnet\",<0-3>\r\nOK\r\n") == 15);
    CHECK(mode_mask("+QCFG: \"usbnet\",<0-5>\r\n") == 0);
    CHECK(storage_allowed("SM") && !storage_allowed("SM\";AT+CMGD=1"));
    printf("{\"selfTest\":%s,\"checks\":%d,\"failures\":%d}\n", failures ? "false" : "true", checks, failures);
    return failures ? 1 : 0;
#undef CHECK
}

int main(int argc, char **argv) {
    const char *action = argc > 1 ? argv[1] : "snapshot";
    if (argc == 2 && !strcmp(action, "--self-test")) return self_test();
    bool reset = !strcmp(action, "usb-reset"), restart = !strcmp(action, "restart");
    bool mode = !strcmp(action, "mode-info"), change = !strcmp(action, "set-usbnet"), sms = !strcmp(action, "sms");
    int target = UNKNOWN, expected = UNKNOWN;
    bool valid = change ? argc == 5 && parse_integer(argv[2], &target) && target >= 0 && target <= 3 &&
        parse_integer(argv[3], &expected) && expected >= 0 && expected <= 3 && !strcmp(argv[4], "--confirm") :
        sms ? (argc == 3 || (argc == 4 && !strcmp(argv[3], "--allow-mark-read"))) && (!strcmp(argv[2], "ME") || !strcmp(argv[2], "SM")) :
        argc <= 2 && (!strcmp(action, "snapshot") || !strcmp(action, "probe") || mode || reset || restart);
    if (!valid) {
        fputs("Usage: modem-helper snapshot|probe|mode-info|usb-reset|restart|sms ME|SM [--allow-mark-read]|set-usbnet TARGET EXPECTED --confirm|--self-test\n", stderr); return 64;
    }
    signal(SIGINT, on_signal); signal(SIGTERM, on_signal); signal(SIGALRM, on_alarm);
    alarm(sms ? 25 : 15);
    Snapshot s = snapshot_empty();
    Modem m = {.deadline = monotonic_ms() + (sms ? 21000 : 14500)};
    if (!open_modem(&m, &s)) goto finish;
    if (reset) {
        int rc = libusb_reset_device(m.handle);
        s.success = rc == 0;
        if (rc != 0) snprintf(s.error, FIELD, "USB reset: %s (re-enumeration may have changed the handle; recovery is not confirmed)", libusb_error_name(rc));
        goto finish;
    }
    if (!claim_at(&m, &s) || !drain_input(&m, &s)) goto finish;
    char response[RESPONSE], error[FIELD];
    int rc = at_query(&m, "AT", response, error, 1200);
    s.atOK = rc == 1;
    if (!s.atOK) { snprintf(s.error, FIELD, "AT probe: %s", error); goto finish; }
    if (sms) read_sms(&m, &s, argv[2], argc == 4);
    else if (change) switch_mode(&m, &s, target, expected);
    else if (mode) mode_info(&m, &s);
    else if (restart) {
        rc = at_query(&m, "AT+CFUN=1,1", response, error, 3000);
        s.success = rc == 1;
        if (!s.success) snprintf(s.error, FIELD, "Restart acknowledgement not confirmed: %s", error);
    } else if (!strcmp(action, "snapshot")) collect_snapshot(&m, &s);
    else s.success = true;
finish:
    if (m.claimed && m.handle) libusb_release_interface(m.handle, AT_INTERFACE);
    if (m.handle) libusb_close(m.handle);
    if (m.context) libusb_exit(m.context);
    alarm(0);
    if (interrupted) { s.success = false; copy_string(s.error, FIELD, "helper interrupted"); }
    print_snapshot(&s, action);
    return s.success ? 0 : 2;
}
