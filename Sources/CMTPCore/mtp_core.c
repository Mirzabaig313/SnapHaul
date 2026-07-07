// CMTPCore — Native MTP protocol implementation for SnapHaul
// Copyright (c) 2026 SnapHaul Contributors — GPL-3.0
//
// Pure C MTP stack. All USB I/O is performed via callbacks provided by Swift.
// Platform: macOS only (uses F_NOCACHE, F_FULLFSYNC, posix_memalign with 16 KB pages).
//
// Design notes:
// - UTF-16LE string handling is BMP-only. Filenames outside the Basic Multilingual
//   Plane (supplementary characters) are replaced with '?'. This covers 99.9% of
//   real-world Android filenames.
// - receive_data_phase() rejects payloads larger than the session buffer (4 MB default).
//   This means GetObjectHandles on a device with >1M files will fail. Acceptable for
//   now — such devices are extremely rare and would need a streaming approach.
// - OpenSession uses transaction_id=1 (spec-compliant: IDs start at 1, not 0).

#include "include/mtp_core.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

// Platform-specific direct I/O and flush
#ifdef __APPLE__
  #define SET_NOCACHE(fd) fcntl((fd), F_NOCACHE, 1)
  #define FULL_FSYNC(fd)  fcntl((fd), F_FULLFSYNC)
#else
  #define SET_NOCACHE(fd) ((void)0)
  #define FULL_FSYNC(fd)  fsync((fd))
#endif

// ============================================================================
// Internal Helpers
// ============================================================================

static const size_t DEFAULT_DATA_BUF_SIZE = 4 * 1024 * 1024;
static const size_t PAGE_ALIGN = 16384;

static inline uint16_t rd16le(const uint8_t *p) {
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}
static inline uint32_t rd32le(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static inline uint64_t rd64le(const uint8_t *p) {
    return (uint64_t)rd32le(p) | ((uint64_t)rd32le(p + 4) << 32);
}
static inline void wr16le(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v); p[1] = (uint8_t)(v >> 8);
}
static inline void wr32le(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v); p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}

static void set_error(mtp_session_t *s, const char *msg) {
    strncpy(s->last_error, msg, sizeof(s->last_error) - 1);
    s->last_error[sizeof(s->last_error) - 1] = '\0';
}

// Write all bytes to a file descriptor, handling short writes and EINTR.
static int write_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    size_t written = 0;
    while (written < len) {
        ssize_t w = write(fd, p + written, len - written);
        if (w < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        written += (size_t)w;
    }
    return 0;
}

// Read exactly `len` bytes from a file descriptor, handling short reads and EINTR.
static ssize_t read_all(int fd, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    size_t total = 0;
    while (total < len) {
        ssize_t n = read(fd, p + total, len - total);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) break;
        total += (size_t)n;
    }
    return (ssize_t)total;
}

// Send all bytes via USB bulk-out, verifying exact byte count.
static int usb_write_all(mtp_session_t *s, const void *buf, size_t len) {
    ssize_t sent = s->usb.bulk_write(buf, len, s->usb.context);
    if (sent < 0 || (size_t)sent != len) {
        set_error(s, "USB bulk write: incomplete or failed");
        return -1;
    }
    return 0;
}

// Send a complete MTP data container (12-byte header + payload) as a SINGLE
// USB bulk transfer. Splitting the container across two bulk writes is unsafe:
// when the first write's length is a multiple of the endpoint max-packet size
// (or just smaller than it) the USB host controller emits a short packet,
// which the device interprets as end-of-data-phase. Xiaomi/HyperOS, Samsung
// One UI, and Huawei EMUI have all been observed returning 0x201D
// (Invalid Parameter) or 0x2002 (General Error) when this happens.
//
// We coalesce by temporarily staging the header into a scratch buffer on the
// stack, then writing header||payload in one call. For payloads already sitting
// at the start of session->data_buf, callers can use usb_write_container_inplace
// which prepends the header inside the session buffer (no copy required as long
// as data_buf_size is at least payload_size + 12).
static int usb_write_container(mtp_session_t *s,
                               uint16_t type, uint16_t code,
                               const void *payload, size_t payload_len) {
    if (payload_len > 0xFFFFFFFFULL - MTP_CONTAINER_HEADER_SIZE) {
        set_error(s, "Container payload too large for single transfer");
        return -1;
    }
    uint32_t total = (uint32_t)(MTP_CONTAINER_HEADER_SIZE + payload_len);

    // Small header + payload fit in one write by staging into data_buf.
    // We guarantee data_buf is large enough at session create time
    // (default 4 MB, aligned), so ObjectInfo/OPL datasets always fit.
    if (payload_len + MTP_CONTAINER_HEADER_SIZE > s->data_buf_size) {
        set_error(s, "Container exceeds data buffer size");
        return -1;
    }

    uint8_t *buf = (uint8_t *)s->data_buf;
    if (payload == buf) {
        memmove(buf + MTP_CONTAINER_HEADER_SIZE, buf, payload_len);
    } else if (payload_len > 0) {
        memcpy(buf + MTP_CONTAINER_HEADER_SIZE, payload, payload_len);
    }

    wr32le(buf, total);
    wr16le(buf + 4, type);
    wr16le(buf + 6, code);
    wr32le(buf + 8, s->transaction_id);

    return usb_write_all(s, buf, total);
}

// ============================================================================
// Container Building & Parsing
// ============================================================================

int mtp_build_command(void *buf, uint16_t code, uint32_t txn_id,
                      const uint32_t *params, int param_count) {
    if (!buf || param_count < 0 || param_count > MTP_MAX_PARAMS) return -1;

    uint8_t *p = (uint8_t *)buf;
    uint32_t length = MTP_CONTAINER_HEADER_SIZE + (uint32_t)(param_count * 4);

    wr32le(p, length);
    wr16le(p + 4, MTP_CONTAINER_COMMAND);
    wr16le(p + 6, code);
    wr32le(p + 8, txn_id);

    for (int i = 0; i < param_count; i++) {
        wr32le(p + 12 + i * 4, params[i]);
    }
    return (int)length;
}

int mtp_parse_response(const void *buf, size_t len, mtp_container_t *out,
                       uint32_t *params, int *param_count) {
    if (!buf || !out || len < MTP_CONTAINER_HEADER_SIZE) return -1;

    const uint8_t *p = (const uint8_t *)buf;
    out->length = rd32le(p);
    out->type = rd16le(p + 4);
    out->code = rd16le(p + 6);
    out->transaction_id = rd32le(p + 8);

    if (out->type != MTP_CONTAINER_RESPONSE) return -1;
    if (out->length < MTP_CONTAINER_HEADER_SIZE) return -1;
    if (out->length > len) return -1;

    uint32_t param_bytes = out->length - MTP_CONTAINER_HEADER_SIZE;
    if (param_bytes % 4 != 0) return -1;

    int n_params = (int)(param_bytes / 4);
    if (n_params > MTP_MAX_PARAMS) n_params = MTP_MAX_PARAMS;

    if (params && param_count) {
        *param_count = n_params;
        for (int i = 0; i < n_params; i++) {
            params[i] = rd32le(p + 12 + i * 4);
        }
    }
    return 0;
}

int mtp_parse_data_header(const void *buf, size_t len, mtp_container_t *out,
                          size_t *payload_offset) {
    if (!buf || !out || len < MTP_CONTAINER_HEADER_SIZE) return -1;

    const uint8_t *p = (const uint8_t *)buf;
    out->length = rd32le(p);
    out->type = rd16le(p + 4);
    out->code = rd16le(p + 6);
    out->transaction_id = rd32le(p + 8);

    if (out->type != MTP_CONTAINER_DATA) return -1;
    // 0xFFFFFFFF is valid for large transfers; otherwise must be >= header size
    if (out->length != 0xFFFFFFFF && out->length < MTP_CONTAINER_HEADER_SIZE) return -1;

    if (payload_offset) *payload_offset = MTP_CONTAINER_HEADER_SIZE;
    return 0;
}

// ============================================================================
// MTP String Parsing (UTF-16LE → UTF-8, BMP only)
// ============================================================================

int mtp_parse_string(const uint8_t *src, size_t src_len,
                     char *dst, size_t dst_size) {
    if (!src || !dst || src_len < 1 || dst_size < 1) return -1;

    uint8_t char_count = src[0];
    if (char_count == 0) { dst[0] = '\0'; return 1; }

    size_t bytes_needed = 1 + (size_t)char_count * 2;
    if (bytes_needed > src_len) return -1;

    size_t dst_pos = 0;
    const uint8_t *str_data = src + 1;

    for (int i = 0; i < char_count - 1 && dst_pos < dst_size - 1; i++) {
        uint16_t ch = rd16le(str_data + i * 2);
        if (ch == 0) break;

        if (ch < 0x80) {
            dst[dst_pos++] = (char)ch;
        } else if (ch < 0x800) {
            if (dst_pos + 2 > dst_size - 1) break;
            dst[dst_pos++] = (char)(0xC0 | (ch >> 6));
            dst[dst_pos++] = (char)(0x80 | (ch & 0x3F));
        } else {
            if (dst_pos + 3 > dst_size - 1) break;
            dst[dst_pos++] = (char)(0xE0 | (ch >> 12));
            dst[dst_pos++] = (char)(0x80 | ((ch >> 6) & 0x3F));
            dst[dst_pos++] = (char)(0x80 | (ch & 0x3F));
        }
    }
    dst[dst_pos] = '\0';
    return (int)bytes_needed;
}

int mtp_build_string(const char *utf8, uint8_t *dst, size_t dst_size) {
    if (!utf8 || !dst || dst_size < 3) return -1;

    size_t utf8_len = strlen(utf8);
    size_t max_chars = (dst_size - 1) / 2;

    uint8_t *out = dst + 1;
    int char_count = 0;
    size_t i = 0;

    while (i < utf8_len && (size_t)(char_count + 1) < max_chars) {
        uint32_t cp;
        uint8_t c = (uint8_t)utf8[i];

        if (c < 0x80) { cp = c; i += 1; }
        else if ((c & 0xE0) == 0xC0 && i + 1 < utf8_len) {
            cp = ((uint32_t)(c & 0x1F) << 6) | (utf8[i+1] & 0x3F);
            i += 2;
        } else if ((c & 0xF0) == 0xE0 && i + 2 < utf8_len) {
            cp = ((uint32_t)(c & 0x0F) << 12) | ((uint32_t)(utf8[i+1] & 0x3F) << 6) | (utf8[i+2] & 0x3F);
            i += 3;
        } else {
            cp = '?'; i += 1;
        }

        if (cp > 0xFFFF) cp = '?';  // BMP only — supplementary planes not supported
        wr16le(out + char_count * 2, (uint16_t)cp);
        char_count++;
    }

    wr16le(out + char_count * 2, 0);  // Null terminator
    char_count++;

    dst[0] = (uint8_t)char_count;
    return 1 + char_count * 2;
}

// ============================================================================
// Internal: Send command and receive response with validation
// ============================================================================

static int send_command(mtp_session_t *s, uint16_t code,
                        const uint32_t *params, int param_count) {
    s->transaction_id++;
    int cmd_len = mtp_build_command(s->cmd_buf, code, s->transaction_id, params, param_count);
    if (cmd_len < 0) { set_error(s, "Failed to build command"); return -1; }
    return usb_write_all(s, s->cmd_buf, (size_t)cmd_len);
}

static int receive_response(mtp_session_t *s, uint32_t *params, int *param_count) {
    ssize_t n = s->usb.bulk_read(s->cmd_buf, 64, s->usb.context);
    if (n < MTP_CONTAINER_HEADER_SIZE) { set_error(s, "USB bulk read failed (response)"); return -1; }

    mtp_container_t resp;
    if (mtp_parse_response(s->cmd_buf, (size_t)n, &resp, params, param_count) != 0) {
        set_error(s, "Invalid response container");
        return -1;
    }

    if (resp.transaction_id != s->transaction_id) {
        snprintf(s->last_error, sizeof(s->last_error),
                 "Transaction ID mismatch: expected %u, got %u",
                 s->transaction_id, resp.transaction_id);
        return -1;
    }

    s->last_response_code = resp.code;
    if (resp.code != MTP_RESP_OK) {
        snprintf(s->last_error, sizeof(s->last_error),
                 "MTP error: %s (0x%04X)", mtp_response_string(resp.code), resp.code);
        return -1;
    }
    return 0;
}

static ssize_t receive_data_phase(mtp_session_t *s) {
    ssize_t n = s->usb.bulk_read(s->data_buf, s->data_buf_size, s->usb.context);
    if (n < MTP_CONTAINER_HEADER_SIZE) { set_error(s, "USB bulk read failed (data)"); return -1; }

    mtp_container_t hdr;
    size_t payload_off;
    if (mtp_parse_data_header(s->data_buf, (size_t)n, &hdr, &payload_off) != 0) {
        set_error(s, "Invalid data container");
        return -1;
    }

    if (hdr.transaction_id != s->transaction_id) {
        set_error(s, "Data phase transaction ID mismatch");
        return -1;
    }

    if (hdr.length == 0xFFFFFFFF) {
        set_error(s, "Data phase has indeterminate length (0xFFFFFFFF); not supported for metadata");
        return -1;
    }

    size_t total_payload = hdr.length - MTP_CONTAINER_HEADER_SIZE;
    size_t received_payload = (size_t)n - payload_off;

    if (total_payload > s->data_buf_size) {
        set_error(s, "Data phase exceeds buffer size");
        return -1;
    }

    if (payload_off > 0 && received_payload > 0) {
        memmove(s->data_buf, (uint8_t *)s->data_buf + payload_off, received_payload);
    }

    if (received_payload >= total_payload) return (ssize_t)total_payload;

    while (received_payload < total_payload) {
        size_t to_read = total_payload - received_payload;
        if (to_read > s->data_buf_size - received_payload)
            to_read = s->data_buf_size - received_payload;
        ssize_t chunk = s->usb.bulk_read(
            (uint8_t *)s->data_buf + received_payload, to_read, s->usb.context);
        if (chunk <= 0) { set_error(s, "USB read failed during data phase"); return -1; }
        received_payload += (size_t)chunk;
    }

    return (ssize_t)total_payload;
}

// ============================================================================
// Session Lifecycle
// ============================================================================

mtp_session_t *mtp_session_create(size_t data_buf_size, mtp_usb_interface_t usb) {
    if (data_buf_size == 0) data_buf_size = DEFAULT_DATA_BUF_SIZE;
    data_buf_size = (data_buf_size + PAGE_ALIGN - 1) & ~(PAGE_ALIGN - 1);

    mtp_session_t *s = calloc(1, sizeof(mtp_session_t));
    if (!s) return NULL;

    s->usb = usb;
    s->data_buf_size = data_buf_size;

    if (posix_memalign(&s->cmd_buf, PAGE_ALIGN, 64) != 0) { free(s); return NULL; }
    if (posix_memalign(&s->data_buf, PAGE_ALIGN, data_buf_size) != 0) {
        free(s->cmd_buf); free(s); return NULL;
    }
    return s;
}

void mtp_session_destroy(mtp_session_t *session) {
    if (!session) return;
    if (session->is_open) mtp_close_session(session);
    free(session->cmd_buf);
    free(session->data_buf);
    free(session);
}

int mtp_open_session(mtp_session_t *session) {
    if (!session) return -1;
    if (session->is_open) return 0;

    session->session_id = 1;

    // OpenSession uses transaction_id=0 per MTP spec (no session exists yet).
    // After OpenSession succeeds, subsequent commands start at txn_id=1.
    session->transaction_id = 0;
    uint32_t params[1] = { session->session_id };
    int cmd_len = mtp_build_command(session->cmd_buf, MTP_OP_OPEN_SESSION, 0, params, 1);
    if (cmd_len < 0) { set_error(session, "Failed to build OpenSession"); return -1; }
    if (usb_write_all(session, session->cmd_buf, (size_t)cmd_len) != 0) return -1;

    // Read response — expect txn_id=0 back
    ssize_t n = session->usb.bulk_read(session->cmd_buf, 64, session->usb.context);
    if (n < MTP_CONTAINER_HEADER_SIZE) { set_error(session, "OpenSession: no response"); return -1; }

    mtp_container_t resp;
    if (mtp_parse_response(session->cmd_buf, (size_t)n, &resp, NULL, NULL) != 0) {
        set_error(session, "OpenSession: invalid response");
        return -1;
    }

    session->last_response_code = resp.code;
    if (resp.code != MTP_RESP_OK && resp.code != MTP_RESP_SESSION_ALREADY_OPEN) {
        snprintf(session->last_error, sizeof(session->last_error),
                 "OpenSession failed: %s (0x%04X)", mtp_response_string(resp.code), resp.code);
        return -1;
    }

    session->is_open = 1;
    session->transaction_id = 0;  // Next send_command() will increment to 1
    return 0;
}

int mtp_close_session(mtp_session_t *session) {
    if (!session || !session->is_open) return 0;
    send_command(session, MTP_OP_CLOSE_SESSION, NULL, 0);
    receive_response(session, NULL, NULL);
    session->is_open = 0;
    return 0;
}

// ============================================================================
// Storage Operations
// ============================================================================

int mtp_get_storage_ids(mtp_session_t *session) {
    if (!session || !session->is_open) return -1;
    if (send_command(session, MTP_OP_GET_STORAGE_IDS, NULL, 0) != 0) return -1;

    ssize_t data_len = receive_data_phase(session);
    if (data_len < 4) return -1;
    if (receive_response(session, NULL, NULL) != 0) return -1;

    const uint8_t *p = (const uint8_t *)session->data_buf;
    uint32_t count = rd32le(p);

    if ((size_t)(4 + count * 4) > (size_t)data_len) {
        set_error(session, "Storage ID array exceeds data length");
        return -1;
    }

    session->storage_count = (int)(count > 16 ? 16 : count);
    for (int i = 0; i < session->storage_count; i++) {
        session->storage_ids[i] = rd32le(p + 4 + i * 4);
    }
    return session->storage_count;
}

int mtp_get_storage_info(mtp_session_t *session, uint32_t storage_id,
                         mtp_storage_info_t *info) {
    if (!session || !session->is_open || !info) return -1;

    uint32_t params[1] = { storage_id };
    if (send_command(session, MTP_OP_GET_STORAGE_INFO, params, 1) != 0) return -1;

    ssize_t data_len = receive_data_phase(session);
    if (data_len < 26) return -1;
    if (receive_response(session, NULL, NULL) != 0) return -1;

    const uint8_t *p = (const uint8_t *)session->data_buf;
    memset(info, 0, sizeof(mtp_storage_info_t));
    info->storage_id = storage_id;
    info->storage_type = rd16le(p);
    info->filesystem_type = rd16le(p + 2);
    info->access_capability = rd16le(p + 4);
    info->max_capacity = rd64le(p + 6);
    info->free_space = rd64le(p + 14);

    size_t off = 26;
    if (off < (size_t)data_len) {
        int consumed = mtp_parse_string(p + off, (size_t)data_len - off,
                                        info->description, sizeof(info->description));
        if (consumed > 0) off += (size_t)consumed;
    }
    if (off < (size_t)data_len) {
        mtp_parse_string(p + off, (size_t)data_len - off,
                         info->volume_label, sizeof(info->volume_label));
    }
    return 0;
}

// ============================================================================
// Object Enumeration
// ============================================================================

int mtp_get_object_handles(mtp_session_t *session, uint32_t storage_id,
                           uint32_t parent_handle, uint32_t format_filter,
                           uint32_t *handles, int max_handles) {
    if (!session || !session->is_open || !handles || max_handles <= 0) return -1;

    uint32_t params[3] = { storage_id, format_filter, parent_handle };
    if (send_command(session, MTP_OP_GET_OBJECT_HANDLES, params, 3) != 0) return -1;

    ssize_t data_len = receive_data_phase(session);
    if (data_len < 4) return -1;
    if (receive_response(session, NULL, NULL) != 0) return -1;

    const uint8_t *p = (const uint8_t *)session->data_buf;
    uint32_t count = rd32le(p);

    if ((size_t)(4 + count * 4) > (size_t)data_len) {
        set_error(session, "Object handle array exceeds data length");
        return -1;
    }

    int result_count = (int)(count > (uint32_t)max_handles ? (uint32_t)max_handles : count);
    for (int i = 0; i < result_count; i++) {
        handles[i] = rd32le(p + 4 + i * 4);
    }
    return result_count;
}

int mtp_get_object_info(mtp_session_t *session, uint32_t handle,
                        mtp_object_info_t *info) {
    if (!session || !session->is_open || !info) return -1;

    uint32_t params[1] = { handle };
    if (send_command(session, MTP_OP_GET_OBJECT_INFO, params, 1) != 0) return -1;

    ssize_t data_len = receive_data_phase(session);
    if (data_len < 52) return -1;
    if (receive_response(session, NULL, NULL) != 0) return -1;

    const uint8_t *p = (const uint8_t *)session->data_buf;
    memset(info, 0, sizeof(mtp_object_info_t));

    info->object_handle = handle;
    info->storage_id = rd32le(p);
    info->object_format = rd16le(p + 4);
    info->compressed_size = rd32le(p + 8);
    info->object_size_64 = (uint64_t)info->compressed_size;

    // Samsung Galaxy quirk: some firmware emits a 64-bit ObjectCompressedSize
    // (8 bytes at offset 8) instead of the spec-mandated 32-bit value. This
    // shifts every later field by +4. libmtp detects it by looking at
    // filenamelen position: in the standard layout it's at offset 52, in the
    // Samsung variant it's at 56. We latch the detection into session->ocs64
    // so outgoing SendObjectInfo datasets stay compatible.
    size_t header_len = 52;
    if (data_len >= 57 && p[52] == 0 && p[56] != 0) {
        header_len = 56;
        if (!session->ocs64) session->ocs64 = 1;

        // In the Samsung variant, offset 8 carries the low 32 bits and
        // offset 12 carries the high 32 bits of a 64-bit size.
        info->object_size_64 =
            ((uint64_t)rd32le(p + 12) << 32) | (uint64_t)rd32le(p + 8);
    }

    size_t parent_off   = (header_len == 52) ? 38 : 42;
    size_t assoc_type_off = (header_len == 52) ? 42 : 46;

    info->parent_object = rd32le(p + parent_off);
    info->association_type = rd16le(p + assoc_type_off);

    size_t off = header_len;
    if (off < (size_t)data_len) {
        int consumed = mtp_parse_string(p + off, (size_t)data_len - off,
                                        info->filename, sizeof(info->filename));
        if (consumed > 0) off += (size_t)consumed;
    }
    if (off < (size_t)data_len) {
        int consumed = mtp_parse_string(p + off, (size_t)data_len - off,
                                        info->date_created, sizeof(info->date_created));
        if (consumed > 0) off += (size_t)consumed;
    }
    if (off < (size_t)data_len) {
        mtp_parse_string(p + off, (size_t)data_len - off,
                         info->date_modified, sizeof(info->date_modified));
    }
    return 0;
}

int mtp_get_object_info_batch(mtp_session_t *session, const uint32_t *handles,
                              mtp_object_info_t *infos, int count) {
    if (!session || !handles || !infos || count <= 0) return -1;
    int success = 0;
    for (int i = 0; i < count; i++) {
        if (mtp_get_object_info(session, handles[i], &infos[i]) == 0) success++;
        else memset(&infos[i], 0, sizeof(mtp_object_info_t));
    }
    return success;
}


// ============================================================================
// File Transfer — The Hot Path
// ============================================================================

int mtp_get_object_to_fd(mtp_session_t *session, uint32_t handle,
                         int dst_fd, uint64_t file_size,
                         uint64_t *bytes_written,
                         void (*progress_fn)(uint64_t, void *),
                         void *progress_ctx) {
    if (!session || !session->is_open || dst_fd < 0 || !bytes_written) return -1;
    *bytes_written = 0;

    SET_NOCACHE(dst_fd);

    uint32_t params[1] = { handle };
    if (send_command(session, MTP_OP_GET_OBJECT, params, 1) != 0) return -1;

    ssize_t first_read = session->usb.bulk_read(
        session->data_buf, session->data_buf_size, session->usb.context);
    if (first_read < MTP_CONTAINER_HEADER_SIZE) {
        set_error(session, "Failed to read data phase header");
        return -1;
    }

    mtp_container_t data_hdr;
    size_t payload_off;
    if (mtp_parse_data_header(session->data_buf, (size_t)first_read, &data_hdr, &payload_off) != 0) {
        set_error(session, "Invalid data container in GetObject");
        return -1;
    }
    if (data_hdr.transaction_id != session->transaction_id) {
        set_error(session, "GetObject: data phase transaction ID mismatch");
        return -1;
    }
    if (data_hdr.code != MTP_OP_GET_OBJECT) {
        set_error(session, "GetObject: unexpected operation code in data phase");
        return -1;
    }

    uint64_t total_payload = (data_hdr.length == 0xFFFFFFFF)
        ? file_size
        : (uint64_t)(data_hdr.length - MTP_CONTAINER_HEADER_SIZE);

    // Write first payload chunk using write_all (handles short writes)
    size_t first_payload = (size_t)first_read - payload_off;
    if (first_payload > 0) {
        if (write_all(dst_fd, (uint8_t *)session->data_buf + payload_off, first_payload) != 0) {
            set_error(session, "Write to destination failed");
            return -1;
        }
        *bytes_written += (uint64_t)first_payload;
    }

    if (progress_fn) progress_fn(*bytes_written, progress_ctx);

    while (*bytes_written < total_payload) {
        size_t remaining = (size_t)(total_payload - *bytes_written);
        size_t to_read = remaining < session->data_buf_size ? remaining : session->data_buf_size;

        ssize_t n = session->usb.bulk_read(session->data_buf, to_read, session->usb.context);
        if (n <= 0) { set_error(session, "USB read failed during transfer"); return -1; }

        if (write_all(dst_fd, session->data_buf, (size_t)n) != 0) {
            set_error(session, "Disk write failed during transfer");
            return -1;
        }
        *bytes_written += (uint64_t)n;

        if (progress_fn) progress_fn(*bytes_written, progress_ctx);
    }

    FULL_FSYNC(dst_fd);
    return receive_response(session, NULL, NULL);
}

int mtp_get_partial_object_to_fd(mtp_session_t *session, uint32_t handle,
                                 uint64_t offset, uint64_t length,
                                 int dst_fd, uint64_t *bytes_written) {
    if (!session || !session->is_open || dst_fd < 0 || !bytes_written) return -1;
    *bytes_written = 0;

    if (offset > 0xFFFFFFFF || length > 0xFFFFFFFF) {
        set_error(session, "GetPartialObject: offset/length exceed 32-bit MTP spec limit");
        return -1;
    }

    SET_NOCACHE(dst_fd);

    uint32_t params[3] = { handle, (uint32_t)offset, (uint32_t)length };
    if (send_command(session, MTP_OP_GET_PARTIAL_OBJECT, params, 3) != 0) return -1;

    ssize_t first_read = session->usb.bulk_read(
        session->data_buf, session->data_buf_size, session->usb.context);
    if (first_read < MTP_CONTAINER_HEADER_SIZE) {
        set_error(session, "Failed to read partial object data");
        return -1;
    }

    mtp_container_t data_hdr;
    size_t payload_off;
    if (mtp_parse_data_header(session->data_buf, (size_t)first_read, &data_hdr, &payload_off) != 0) {
        set_error(session, "Invalid data container in GetPartialObject");
        return -1;
    }
    if (data_hdr.transaction_id != session->transaction_id) {
        set_error(session, "GetPartialObject: data phase transaction ID mismatch");
        return -1;
    }
    if (data_hdr.code != MTP_OP_GET_PARTIAL_OBJECT) {
        set_error(session, "GetPartialObject: unexpected operation code in data phase");
        return -1;
    }
    if (data_hdr.length < MTP_CONTAINER_HEADER_SIZE && data_hdr.length != 0xFFFFFFFF) {
        set_error(session, "GetPartialObject: invalid container length");
        return -1;
    }

    uint64_t total_payload = (data_hdr.length == 0xFFFFFFFF)
        ? length
        : (uint64_t)(data_hdr.length - MTP_CONTAINER_HEADER_SIZE);

    size_t first_payload = (size_t)first_read - payload_off;
    if (first_payload > 0) {
        if (write_all(dst_fd, (uint8_t *)session->data_buf + payload_off, first_payload) != 0) {
            set_error(session, "Write failed"); return -1;
        }
        *bytes_written += (uint64_t)first_payload;
    }

    while (*bytes_written < total_payload) {
        size_t remaining = (size_t)(total_payload - *bytes_written);
        size_t to_read = remaining < session->data_buf_size ? remaining : session->data_buf_size;

        ssize_t n = session->usb.bulk_read(session->data_buf, to_read, session->usb.context);
        if (n <= 0) { set_error(session, "USB read failed"); return -1; }

        if (write_all(dst_fd, session->data_buf, (size_t)n) != 0) {
            set_error(session, "Disk write failed"); return -1;
        }
        *bytes_written += (uint64_t)n;
    }

    FULL_FSYNC(dst_fd);
    return receive_response(session, NULL, NULL);
}

int mtp_get_partial_object_64_to_fd(mtp_session_t *session, uint32_t handle,
                                    uint64_t offset, uint64_t length,
                                    int dst_fd, uint64_t *bytes_written) {
    if (!session || !session->is_open || dst_fd < 0 || !bytes_written) return -1;
    *bytes_written = 0;

    SET_NOCACHE(dst_fd);

    // Android's GetPartialObject64 takes: handle, offset_low, offset_high, length_low, length_high
    // 5 parameters (the maximum MTP allows)
    uint32_t params[5] = {
        handle,
        (uint32_t)(offset & 0xFFFFFFFF),
        (uint32_t)(offset >> 32),
        (uint32_t)(length & 0xFFFFFFFF),
        (uint32_t)(length >> 32)
    };
    if (send_command(session, MTP_OP_GET_PARTIAL_OBJECT_64, params, 5) != 0) return -1;

    ssize_t first_read = session->usb.bulk_read(
        session->data_buf, session->data_buf_size, session->usb.context);
    if (first_read < MTP_CONTAINER_HEADER_SIZE) {
        set_error(session, "Failed to read GetPartialObject64 data");
        return -1;
    }

    mtp_container_t data_hdr;
    size_t payload_off;
    if (mtp_parse_data_header(session->data_buf, (size_t)first_read, &data_hdr, &payload_off) != 0) {
        set_error(session, "Invalid data container in GetPartialObject64");
        return -1;
    }
    if (data_hdr.transaction_id != session->transaction_id) {
        set_error(session, "GetPartialObject64: transaction ID mismatch");
        return -1;
    }
    if (data_hdr.code != MTP_OP_GET_PARTIAL_OBJECT_64) {
        set_error(session, "GetPartialObject64: unexpected operation code in data phase");
        return -1;
    }

    uint64_t total_payload = (data_hdr.length == 0xFFFFFFFF) ? length
        : (uint64_t)(data_hdr.length - MTP_CONTAINER_HEADER_SIZE);

    size_t first_payload = (size_t)first_read - payload_off;
    if (first_payload > 0) {
        if (write_all(dst_fd, (uint8_t *)session->data_buf + payload_off, first_payload) != 0) {
            set_error(session, "Write failed in GetPartialObject64");
            return -1;
        }
        *bytes_written += (uint64_t)first_payload;
    }

    while (*bytes_written < total_payload) {
        size_t remaining = (size_t)(total_payload - *bytes_written);
        size_t to_read = remaining < session->data_buf_size ? remaining : session->data_buf_size;

        ssize_t n = session->usb.bulk_read(session->data_buf, to_read, session->usb.context);
        if (n <= 0) { set_error(session, "USB read failed in GetPartialObject64"); return -1; }

        if (write_all(dst_fd, session->data_buf, (size_t)n) != 0) {
            set_error(session, "Disk write failed in GetPartialObject64");
            return -1;
        }
        *bytes_written += (uint64_t)n;
    }

    FULL_FSYNC(dst_fd);
    return receive_response(session, NULL, NULL);
}

// ============================================================================
// Object Management
// ============================================================================

int mtp_delete_object(mtp_session_t *session, uint32_t handle) {
    if (!session || !session->is_open) return -1;
    uint32_t params[1] = { handle };
    if (send_command(session, MTP_OP_DELETE_OBJECT, params, 1) != 0) return -1;
    return receive_response(session, NULL, NULL);
}

int mtp_send_object_from_fd(mtp_session_t *session, uint32_t parent_handle,
                            uint32_t storage_id, const char *filename,
                            uint64_t file_size, uint16_t format,
                            int src_fd, uint32_t *new_handle,
                            void (*progress_fn)(uint64_t, void *),
                            void *progress_ctx) {
    if (!session || !session->is_open || !filename || src_fd < 0) return -1;

    fprintf(stderr, "[MTP-SEND] Starting send: '%s' size=%llu bytes (%.1f GB) format=0x%04x\n",
            filename, file_size, (double)file_size / 1073741824.0, format);
    fprintf(stderr, "[MTP-SEND] Parent handle=0x%08x, storage=0x%08x\n", parent_handle, storage_id);

    uint8_t *d = (uint8_t *)session->data_buf;
    size_t header_len = session->ocs64 ? 56 : 52;
    memset(d, 0, header_len);
    wr32le(d, storage_id);
    wr16le(d + 4, format);
    if (session->ocs64) {
        // Samsung ocs64 variant: write full 64-bit size (low, high) at 8/12.
        wr32le(d + 8, (uint32_t)(file_size & 0xFFFFFFFFULL));
        wr32le(d + 12, (uint32_t)(file_size >> 32));
    } else if (file_size > 0xFFFFFFFFULL) {
        // Standard 32-bit slot can't hold the real size; use the spec kludge.
        wr32le(d + 8, 0xFFFFFFFFU);
    } else {
        wr32le(d + 8, (uint32_t)file_size);
    }
    size_t parent_off     = session->ocs64 ? 42 : 38;
    wr32le(d + parent_off, parent_handle);

    size_t off = header_len;
    int str_len = mtp_build_string(filename, d + off, session->data_buf_size - off);
    if (str_len < 0) { set_error(session, "Failed to encode filename"); return -1; }
    off += (size_t)str_len;
    d[off++] = 0; d[off++] = 0; d[off++] = 0;

    fprintf(stderr, "[MTP-SEND] Phase 1: SendObjectInfo command (compressed_size=0x%08x)...\n",
            (uint32_t)(file_size > 0xFFFFFFFF ? 0xFFFFFFFF : (uint32_t)file_size));

    uint32_t cmd_params[2] = { storage_id, parent_handle };
    if (send_command(session, MTP_OP_SEND_OBJECT_INFO, cmd_params, 2) != 0) {
        fprintf(stderr, "[MTP-SEND] Phase 1: send_command FAILED: %s\n", session->last_error);
        return -1;
    }

    if (usb_write_container(session, MTP_CONTAINER_DATA,
                            MTP_OP_SEND_OBJECT_INFO, d, off) != 0) {
        return -1;
    }

    fprintf(stderr, "[MTP-SEND] Phase 1: waiting for SendObjectInfo response...\n");
    uint32_t resp_params[3];
    int resp_count = 0;
    if (receive_response(session, resp_params, &resp_count) != 0) {
        fprintf(stderr, "[MTP-SEND] Phase 1: FAILED — response error: %s (code=0x%04x)\n",
                session->last_error, session->last_response_code);
        return -1;
    }
    fprintf(stderr, "[MTP-SEND] Phase 1: OK — resp_code=0x%04x, param_count=%d",
            session->last_response_code, resp_count);
    if (resp_count >= 3) fprintf(stderr, ", new_handle=0x%08x", resp_params[2]);
    fprintf(stderr, "\n");
    if (new_handle && resp_count >= 3) *new_handle = resp_params[2];

    if (file_size > 0xFFFFFFFFULL && !session->ocs64 && resp_count >= 3) {
        fprintf(stderr, "[MTP-SEND] Setting 64-bit ObjectSize property (%llu bytes)...\n", file_size);
        uint32_t obj_handle = resp_params[2];
        uint32_t prop_params[2] = { obj_handle, MTP_PROP_OBJECT_SIZE };
        if (send_command(session, MTP_OP_SET_OBJECT_PROP_VALUE, prop_params, 2) == 0) {
            uint8_t size_buf[8];
            size_buf[0] = (uint8_t)(file_size & 0xFF);
            size_buf[1] = (uint8_t)((file_size >> 8) & 0xFF);
            size_buf[2] = (uint8_t)((file_size >> 16) & 0xFF);
            size_buf[3] = (uint8_t)((file_size >> 24) & 0xFF);
            size_buf[4] = (uint8_t)((file_size >> 32) & 0xFF);
            size_buf[5] = (uint8_t)((file_size >> 40) & 0xFF);
            size_buf[6] = (uint8_t)((file_size >> 48) & 0xFF);
            size_buf[7] = (uint8_t)((file_size >> 56) & 0xFF);

            if (usb_write_container(session, MTP_CONTAINER_DATA,
                                    MTP_OP_SET_OBJECT_PROP_VALUE, size_buf, 8) == 0) {
                int prop_resp = receive_response(session, NULL, NULL);
                fprintf(stderr, "[MTP-SEND] SetObjectPropValue result: %d (code=0x%04x)\n",
                        prop_resp, session->last_response_code);
            }
        } else {
            fprintf(stderr, "[MTP-SEND] SetObjectPropValue send_command failed: %s\n", session->last_error);
        }
    }

    // Phase 2: SendObject
    fprintf(stderr, "[MTP-SEND] Phase 2: SendObject (%llu bytes over USB)...\n", file_size);
    if (send_command(session, MTP_OP_SEND_OBJECT, NULL, 0) != 0) {
        fprintf(stderr, "[MTP-SEND] Phase 2: send_command FAILED: %s\n", session->last_error);
        return -1;
    }

    uint64_t total_len = file_size + MTP_CONTAINER_HEADER_SIZE;
    uint32_t send_len = (total_len > 0xFFFFFFFFULL) ? 0xFFFFFFFFU : (uint32_t)total_len;
    fprintf(stderr, "[MTP-SEND] Phase 2: container header length=0x%08x\n", send_len);

    // The 12-byte data-phase header MUST ride with the first chunk of file
    // data in a single USB bulk transfer. Sending it alone produces a short
    // packet (header is 12 bytes, endpoint max packet is 512/1024) which
    // Android's MTP stack interprets as end-of-data — resulting in 0x201D
    // (Invalid Parameter) or 0x2002 (General Error) on the subsequent
    // response. We fill the header in-place at the start of data_buf then
    // read file data into data_buf+12 for the first chunk.
    SET_NOCACHE(src_fd);
    uint8_t *buf = (uint8_t *)session->data_buf;
    wr32le(buf, send_len);
    wr16le(buf + 4, MTP_CONTAINER_DATA);
    wr16le(buf + 6, MTP_OP_SEND_OBJECT);
    wr32le(buf + 8, session->transaction_id);

    uint64_t sent = 0;
    uint64_t last_log = 0;
    int first_chunk = 1;

    while (sent < file_size || first_chunk) {
        size_t remaining = (size_t)(file_size - sent);
        size_t capacity = session->data_buf_size - (first_chunk ? MTP_CONTAINER_HEADER_SIZE : 0);
        size_t to_read = remaining < capacity ? remaining : capacity;

        uint8_t *dst = buf + (first_chunk ? MTP_CONTAINER_HEADER_SIZE : 0);
        ssize_t n = to_read > 0 ? read_all(src_fd, dst, to_read) : 0;
        if (to_read > 0 && n <= 0) {
            fprintf(stderr, "[MTP-SEND] Phase 2: read FAILED at offset %llu (read returned %zd)\n", sent, n);
            set_error(session, "Read from source failed or EOF before expected size");
            return -1;
        }

        size_t write_len = (size_t)n + (first_chunk ? MTP_CONTAINER_HEADER_SIZE : 0);
        if (usb_write_all(session, buf, write_len) != 0) {
            fprintf(stderr, "[MTP-SEND] Phase 2: USB write FAILED at offset %llu: %s\n", sent, session->last_error);
            return -1;
        }
        sent += (uint64_t)n;
        first_chunk = 0;

        if (progress_fn) progress_fn(sent, progress_ctx);

        if (sent - last_log >= 104857600) {
            fprintf(stderr, "[MTP-SEND] Phase 2: %llu / %llu bytes (%.1f%%)\n",
                    sent, file_size, (double)sent / (double)file_size * 100.0);
            last_log = sent;
        }
    }

    fprintf(stderr, "[MTP-SEND] Phase 2: transfer complete — %llu bytes sent\n", sent);

    if (sent != file_size) {
        set_error(session, "SendObject: bytes sent does not match declared file_size");
        return -1;
    }

    fprintf(stderr, "[MTP-SEND] Phase 2: waiting for final response...\n");
    int final_result = receive_response(session, NULL, NULL);
    fprintf(stderr, "[MTP-SEND] Final result: %d (code=0x%04x) %s\n",
            final_result, session->last_response_code,
            final_result == 0 ? "SUCCESS" : session->last_error);
    return final_result;
}

// ============================================================================
// SendObjectPropList — Modern MTP object creation (used by libmtp/OpenMTP)
// ============================================================================

/// Encode a UTF-8 string into MTP-format (length-prefixed UTF-16LE) into buf.
/// Returns the number of bytes written.
static size_t pack_mtp_string_into(uint8_t *dst, size_t dst_size, const char *utf8) {
    if (dst_size < 1) return 0;
    if (!utf8 || !*utf8) {
        dst[0] = 0;  // Empty string: length byte = 0
        return 1;
    }
    int len = mtp_build_string(utf8, dst, dst_size);
    return (len > 0) ? (size_t)len : 0;
}

int mtp_send_object_proplist_from_fd(mtp_session_t *session, uint32_t parent_handle,
                                     uint32_t storage_id, const char *filename,
                                     uint64_t file_size, uint16_t format,
                                     int src_fd, uint32_t *new_handle,
                                     void (*progress_fn)(uint64_t, void *),
                                     void *progress_ctx) {
    if (!session || !session->is_open || !filename || src_fd < 0) return -1;

    fprintf(stderr, "[MTP-SEND-OPL] Starting: '%s' size=%llu (%.1f GB) format=0x%04x parent=0x%08x\n",
            filename, file_size, (double)file_size / 1073741824.0, format, parent_handle);

    // ── Phase 1: SendObjectPropList ──
    // Command params: storage_id, parent_handle, format, size_high32, size_low32
    uint32_t cmd_params[5] = {
        storage_id,
        parent_handle,
        (uint32_t)format,
        (uint32_t)(file_size >> 32),
        (uint32_t)(file_size & 0xFFFFFFFF)
    };

    fprintf(stderr, "[MTP-SEND-OPL] Phase 1: sending command (params: store=0x%08x parent=0x%08x fmt=0x%04x size=%llu)...\n",
            storage_id, parent_handle, format, file_size);

    if (send_command(session, MTP_OP_SEND_OBJECT_PROP_LIST, cmd_params, 5) != 0) {
        fprintf(stderr, "[MTP-SEND-OPL] Phase 1: send_command FAILED: %s\n", session->last_error);
        return -1;
    }

    // ── Build the OPL data payload ──
    // Format: [count: u32] for each prop: [handle: u32][propcode: u16][datatype: u16][value]
    // We send 2 props: ObjectFileName (string) and ObjectSize (uint64).
    // ObjectHandle = 0 means "new object".
    //
    // Some devices require name first, others require size first. libmtp sends
    // name first, so we follow the same convention.

    uint8_t *d = (uint8_t *)session->data_buf;
    size_t off = 0;

    wr32le(d + off, 2);
    off += 4;

    wr32le(d + off, 0);
    off += 4;
    wr16le(d + off, MTP_PROP_OBJECT_FILENAME);
    off += 2;
    wr16le(d + off, MTP_DATATYPE_STRING);
    off += 2;
    size_t name_len = pack_mtp_string_into(d + off, session->data_buf_size - off, filename);
    if (name_len == 0) {
        set_error(session, "Failed to encode filename");
        return -1;
    }
    off += name_len;

    wr32le(d + off, 0);
    off += 4;
    wr16le(d + off, MTP_PROP_OBJECT_SIZE);
    off += 2;
    wr16le(d + off, MTP_DATATYPE_UINT64);
    off += 2;
    wr32le(d + off, (uint32_t)(file_size & 0xFFFFFFFF));
    off += 4;
    wr32le(d + off, (uint32_t)(file_size >> 32));
    off += 4;

    fprintf(stderr, "[MTP-SEND-OPL] Phase 1: sending OPL data (%zu bytes)...\n", off);

    // Single-transfer data phase — see usb_write_container. The payload lives
    // at the start of data_buf; usb_write_container will shift it and prepend
    // the header in place.
    if (usb_write_container(session, MTP_CONTAINER_DATA,
                            MTP_OP_SEND_OBJECT_PROP_LIST, d, off) != 0) {
        fprintf(stderr, "[MTP-SEND-OPL] Phase 1: USB write FAILED: %s\n", session->last_error);
        return -1;
    }

    fprintf(stderr, "[MTP-SEND-OPL] Phase 1: waiting for response...\n");
    uint32_t resp_params[3];
    int resp_count = 0;
    if (receive_response(session, resp_params, &resp_count) != 0) {
        fprintf(stderr, "[MTP-SEND-OPL] Phase 1: response FAILED: %s (code=0x%04x)\n",
                session->last_error, session->last_response_code);
        return -1;
    }
    fprintf(stderr, "[MTP-SEND-OPL] Phase 1: OK — code=0x%04x params=%d",
            session->last_response_code, resp_count);
    // Response params: [store, parent, handle] for newly created object
    if (resp_count >= 3) fprintf(stderr, " new_handle=0x%08x", resp_params[2]);
    fprintf(stderr, "\n");
    if (new_handle && resp_count >= 3) *new_handle = resp_params[2];

    // ── Phase 2: SendObject (transfers file data) ──
    fprintf(stderr, "[MTP-SEND-OPL] Phase 2: SendObject (%llu bytes over USB)...\n", file_size);
    if (send_command(session, MTP_OP_SEND_OBJECT, NULL, 0) != 0) {
        fprintf(stderr, "[MTP-SEND-OPL] Phase 2: send_command FAILED: %s\n", session->last_error);
        return -1;
    }

    // Header + first file chunk in one USB bulk transfer — same rationale as
    // mtp_send_object_from_fd Phase 2.
    uint64_t total_len = file_size + MTP_CONTAINER_HEADER_SIZE;
    uint32_t hdr_len = (total_len > 0xFFFFFFFFULL) ? 0xFFFFFFFFU : (uint32_t)total_len;

    SET_NOCACHE(src_fd);
    uint8_t *buf = (uint8_t *)session->data_buf;
    wr32le(buf, hdr_len);
    wr16le(buf + 4, MTP_CONTAINER_DATA);
    wr16le(buf + 6, MTP_OP_SEND_OBJECT);
    wr32le(buf + 8, session->transaction_id);

    uint64_t sent = 0;
    uint64_t last_log = 0;
    int first_chunk = 1;

    while (sent < file_size || first_chunk) {
        size_t remaining = (size_t)(file_size - sent);
        size_t capacity = session->data_buf_size - (first_chunk ? MTP_CONTAINER_HEADER_SIZE : 0);
        size_t to_read = remaining < capacity ? remaining : capacity;

        uint8_t *dst = buf + (first_chunk ? MTP_CONTAINER_HEADER_SIZE : 0);
        ssize_t n = to_read > 0 ? read_all(src_fd, dst, to_read) : 0;
        if (to_read > 0 && n <= 0) {
            fprintf(stderr, "[MTP-SEND-OPL] Phase 2: read FAILED at offset %llu (returned %zd)\n", sent, n);
            set_error(session, "Read from source failed before EOF");
            return -1;
        }

        size_t write_len = (size_t)n + (first_chunk ? MTP_CONTAINER_HEADER_SIZE : 0);
        if (usb_write_all(session, buf, write_len) != 0) {
            fprintf(stderr, "[MTP-SEND-OPL] Phase 2: USB write FAILED at offset %llu\n", sent);
            return -1;
        }
        sent += (uint64_t)n;
        first_chunk = 0;

        // Per-chunk progress callback (see mtp_send_object_from_fd comments).
        if (progress_fn) progress_fn(sent, progress_ctx);

        // Log progress every 100 MB
        if (sent - last_log >= 104857600) {
            fprintf(stderr, "[MTP-SEND-OPL] Phase 2: %llu / %llu bytes (%.1f%%)\n",
                    sent, file_size, (double)sent / (double)file_size * 100.0);
            last_log = sent;
        }
    }

    fprintf(stderr, "[MTP-SEND-OPL] Phase 2: complete — %llu bytes sent, waiting for response...\n", sent);

    int final = receive_response(session, NULL, NULL);
    fprintf(stderr, "[MTP-SEND-OPL] Final: %d (code=0x%04x) %s\n",
            final, session->last_response_code,
            final == 0 ? "SUCCESS" : session->last_error);
    return final;
}

int mtp_rename_object(mtp_session_t *session, uint32_t handle, const char *new_name) {
    if (!session || !session->is_open || !new_name) return -1;

    uint32_t params[2] = { handle, MTP_PROP_OBJECT_FILENAME };
    if (send_command(session, MTP_OP_SET_OBJECT_PROP_VALUE, params, 2) != 0) return -1;

    uint8_t str_buf[512];
    int str_len = mtp_build_string(new_name, str_buf, sizeof(str_buf));
    if (str_len < 0) { set_error(session, "Failed to encode new name"); return -1; }

    // Single-transfer data phase (see usb_write_container).
    if (usb_write_container(session, MTP_CONTAINER_DATA,
                            MTP_OP_SET_OBJECT_PROP_VALUE, str_buf, (size_t)str_len) != 0) {
        return -1;
    }

    return receive_response(session, NULL, NULL);
}

int mtp_create_folder(mtp_session_t *session, uint32_t parent_handle,
                      uint32_t storage_id, const char *folder_name,
                      uint32_t *new_handle) {
    if (!session || !session->is_open || !folder_name) return -1;

    // Standard 52-byte ObjectInfo header; see mtp_send_object_from_fd for the
    // offset layout. A folder uses ObjectFormat=0x3001 (Association) and
    // AssociationType=0x0001 (GenericFolder) with zero size.
    uint8_t *d = (uint8_t *)session->data_buf;
    size_t header_len = session->ocs64 ? 56 : 52;
    memset(d, 0, header_len);
    wr32le(d, storage_id);
    wr16le(d + 4, MTP_FORMAT_ASSOCIATION);
    // ObjectCompressedSize at 8 — 0 (folders have no data)
    size_t parent_off = session->ocs64 ? 42 : 38;
    size_t assoc_off  = parent_off + 4;
    wr32le(d + parent_off, parent_handle);
    wr16le(d + assoc_off, 0x0001);  // AssociationType = GenericFolder

    size_t off = header_len;
    int str_len = mtp_build_string(folder_name, d + off, session->data_buf_size - off);
    if (str_len < 0) { set_error(session, "Failed to encode folder name"); return -1; }
    off += (size_t)str_len;
    d[off++] = 0; d[off++] = 0; d[off++] = 0;

    uint32_t cmd_params[2] = { storage_id, parent_handle };
    if (send_command(session, MTP_OP_SEND_OBJECT_INFO, cmd_params, 2) != 0) return -1;

    // Single-transfer data phase (see usb_write_container).
    if (usb_write_container(session, MTP_CONTAINER_DATA,
                            MTP_OP_SEND_OBJECT_INFO, d, off) != 0) {
        return -1;
    }

    uint32_t resp_params[3];
    int resp_count = 0;
    if (receive_response(session, resp_params, &resp_count) != 0) return -1;
    if (new_handle && resp_count >= 3) *new_handle = resp_params[2];
    return 0;
}

// ============================================================================
// Device Info
// ============================================================================

// Skip a length-prefixed UCS-2 MTP string. Returns 0 on success, -1 on overflow.
// Format: [count: u8][UTF-16LE chars: 2*count bytes, including null terminator].
// Note: char_count==0 means empty string (just the length byte itself).
static int skip_mtp_string(const uint8_t *buf, size_t len, size_t *offset) {
    if (*offset >= len) return -1;
    uint8_t char_count = buf[*offset];
    size_t needed = 1 + (size_t)char_count * 2;
    if (*offset + needed > len) return -1;
    *offset += needed;
    return 0;
}

// Read an inline uint16_t array (prefixed by a u32 length) and copy up to
// max_out elements into out. Returns 0 on success, advances *offset past the
// array, and stores the actual advertised count in *actual_count.
static int read_uint16_array(const uint8_t *buf, size_t len, size_t *offset,
                             uint16_t *out, int max_out, int *actual_count) {
    if (*offset + 4 > len) return -1;
    uint32_t count = rd32le(buf + *offset);
    *offset += 4;
    if (*offset + (size_t)count * 2 > len) return -1;

    int copy = (int)((count > (uint32_t)max_out) ? (uint32_t)max_out : count);
    if (out && copy > 0) {
        for (int i = 0; i < copy; i++) {
            out[i] = rd16le(buf + *offset + i * 2);
        }
    }
    if (actual_count) *actual_count = copy;
    *offset += (size_t)count * 2;
    return 0;
}

// Parse a raw GetDeviceInfo payload and populate session->supported_ops,
// session->vendor_extension_id, and session->has_device_info.
//
// DeviceInfo dataset layout (MTP spec §5.1.1):
//   0:  StandardVersion          (u16)
//   2:  VendorExtensionID        (u32)
//   6:  VendorExtensionVersion   (u16)
//   8:  VendorExtensionDesc      (string)
//   +0: FunctionalMode           (u16)
//   +2: OperationsSupported      (u16 array)
//   +X: EventsSupported          (u16 array)  — skipped
//   +Y: DevicePropertiesSupported(u16 array)  — skipped
//   +Z: CaptureFormats           (u16 array)  — skipped
//   +W: ImageFormats             (u16 array)  — skipped
//   +...: Manufacturer, Model, DeviceVersion, SerialNumber (strings, optional)
static int parse_device_info(mtp_session_t *session, const uint8_t *data, size_t len) {
    if (len < 12) {
        set_error(session, "DeviceInfo payload too short");
        return -1;
    }
    size_t off = 0;

    // StandardVersion (u16) — we don't currently store it
    off += 2;

    session->vendor_extension_id = rd32le(data + off);
    off += 4;

    // VendorExtensionVersion (u16) — skipped
    off += 2;

    // VendorExtensionDesc (string)
    if (skip_mtp_string(data, len, &off) != 0) {
        set_error(session, "DeviceInfo: malformed VendorExtensionDesc");
        return -1;
    }

    // FunctionalMode (u16)
    if (off + 2 > len) {
        set_error(session, "DeviceInfo: truncated before FunctionalMode");
        return -1;
    }
    off += 2;

    // OperationsSupported — the one we actually care about.
    int ops_count = 0;
    if (read_uint16_array(data, len, &off, session->supported_ops,
                          MTP_MAX_SUPPORTED_OPS, &ops_count) != 0) {
        set_error(session, "DeviceInfo: malformed OperationsSupported array");
        return -1;
    }
    session->supported_ops_count = ops_count;
    session->has_device_info = 1;

    return 0;
}

int mtp_get_device_info(mtp_session_t *session, void *info_buf,
                        size_t info_buf_size, size_t *bytes_out) {
    if (!session || !info_buf || !bytes_out) return -1;

    session->transaction_id++;
    int cmd_len = mtp_build_command(session->cmd_buf, MTP_OP_GET_DEVICE_INFO,
                                    session->transaction_id, NULL, 0);
    if (usb_write_all(session, session->cmd_buf, (size_t)cmd_len) != 0) return -1;

    ssize_t data_len = receive_data_phase(session);
    if (data_len < 0) return -1;

    // Opportunistically parse while the payload is still in the session buffer.
    // Callers that only want the raw bytes still get them via info_buf.
    (void)parse_device_info(session, (const uint8_t *)session->data_buf, (size_t)data_len);

    size_t copy_len = (size_t)data_len < info_buf_size ? (size_t)data_len : info_buf_size;
    memcpy(info_buf, session->data_buf, copy_len);
    *bytes_out = copy_len;

    return receive_response(session, NULL, NULL);
}

int mtp_get_device_info_parsed(mtp_session_t *session) {
    if (!session || !session->is_open) return -1;

    session->has_device_info = 0;
    session->supported_ops_count = 0;
    session->vendor_extension_id = 0;

    if (send_command(session, MTP_OP_GET_DEVICE_INFO, NULL, 0) != 0) return -1;

    ssize_t data_len = receive_data_phase(session);
    if (data_len < 0) return -1;

    if (parse_device_info(session, (const uint8_t *)session->data_buf, (size_t)data_len) != 0) {
        // Drain the response so the transaction stays in sync.
        (void)receive_response(session, NULL, NULL);
        return -1;
    }

    return receive_response(session, NULL, NULL);
}

int mtp_operation_supported(const mtp_session_t *session, uint16_t opcode) {
    if (!session || !session->has_device_info) return 0;
    for (int i = 0; i < session->supported_ops_count; i++) {
        if (session->supported_ops[i] == opcode) return 1;
    }
    return 0;
}

// ============================================================================
// Utility
// ============================================================================

const char *mtp_response_string(uint16_t code) {
    switch (code) {
    case MTP_RESP_OK: return "OK";
    case MTP_RESP_GENERAL_ERROR: return "General Error";
    case MTP_RESP_SESSION_NOT_OPEN: return "Session Not Open";
    case MTP_RESP_INVALID_TRANSACTION_ID: return "Invalid Transaction ID";
    case MTP_RESP_OPERATION_NOT_SUPPORTED: return "Operation Not Supported";
    case MTP_RESP_PARAMETER_NOT_SUPPORTED: return "Parameter Not Supported";
    case MTP_RESP_INCOMPLETE_TRANSFER: return "Incomplete Transfer";
    case MTP_RESP_INVALID_STORAGE_ID: return "Invalid Storage ID";
    case MTP_RESP_INVALID_OBJECT_HANDLE: return "Invalid Object Handle";
    case MTP_RESP_STORE_FULL: return "Store Full";
    case MTP_RESP_STORE_READ_ONLY: return "Store Read Only";
    case MTP_RESP_OBJECT_NOT_FOUND: return "Object Not Found";
    case MTP_RESP_INVALID_PARENT_OBJECT: return "Invalid Parent Object";
    case MTP_RESP_SESSION_ALREADY_OPEN: return "Session Already Open";
    case MTP_RESP_TRANSACTION_CANCELLED: return "Transaction Cancelled";
    default: return "Unknown";
    }
}

const char *mtp_operation_string(uint16_t code) {
    switch (code) {
    case MTP_OP_GET_DEVICE_INFO: return "GetDeviceInfo";
    case MTP_OP_OPEN_SESSION: return "OpenSession";
    case MTP_OP_CLOSE_SESSION: return "CloseSession";
    case MTP_OP_GET_STORAGE_IDS: return "GetStorageIDs";
    case MTP_OP_GET_STORAGE_INFO: return "GetStorageInfo";
    case MTP_OP_GET_NUM_OBJECTS: return "GetNumObjects";
    case MTP_OP_GET_OBJECT_HANDLES: return "GetObjectHandles";
    case MTP_OP_GET_OBJECT_INFO: return "GetObjectInfo";
    case MTP_OP_GET_OBJECT: return "GetObject";
    case MTP_OP_DELETE_OBJECT: return "DeleteObject";
    case MTP_OP_SEND_OBJECT_INFO: return "SendObjectInfo";
    case MTP_OP_SEND_OBJECT: return "SendObject";
    case MTP_OP_GET_PARTIAL_OBJECT: return "GetPartialObject";
    default: return "Unknown";
    }
}
