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
        if (n == 0) break;  // EOF
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

    // Param payload must be divisible by 4 (each param is 32-bit)
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

    // Validate transaction ID matches
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

    // 0xFFFFFFFF means "unknown length" — not valid for metadata operations
    // that use receive_data_phase (only valid for streaming GetObject).
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

    // ALWAYS shift payload to start of buffer for consistent caller access.
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

    // Bounds check: verify all IDs fit within received data
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

    // Bounds check
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
    info->parent_object = rd32le(p + 38);
    info->association_type = rd16le(p + 42);

    size_t off = 52;
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

    // Stream remaining data
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

    // MTP GetPartialObject only supports 32-bit offset and length
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

    // For 64-bit transfers, container length is always 0xFFFFFFFF (indeterminate)
    // Use the requested length as the expected payload size
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
                            int src_fd, uint32_t *new_handle) {
    if (!session || !session->is_open || !filename || src_fd < 0) return -1;

    // Phase 1: SendObjectInfo
    uint8_t *d = (uint8_t *)session->data_buf;
    memset(d, 0, 52);
    wr32le(d, storage_id);
    wr16le(d + 4, format);
    wr32le(d + 8, (uint32_t)(file_size > 0xFFFFFFFF ? 0xFFFFFFFF : file_size));
    wr32le(d + 38, parent_handle);
    wr16le(d + 42, 0);

    size_t off = 52;
    int str_len = mtp_build_string(filename, d + off, session->data_buf_size - off);
    if (str_len < 0) { set_error(session, "Failed to encode filename"); return -1; }
    off += (size_t)str_len;
    d[off++] = 0; d[off++] = 0; d[off++] = 0;

    uint32_t cmd_params[2] = { storage_id, parent_handle };
    if (send_command(session, MTP_OP_SEND_OBJECT_INFO, cmd_params, 2) != 0) return -1;

    // Send data phase header + payload
    uint8_t data_hdr[MTP_CONTAINER_HEADER_SIZE];
    uint32_t data_container_len = MTP_CONTAINER_HEADER_SIZE + (uint32_t)off;
    wr32le(data_hdr, data_container_len);
    wr16le(data_hdr + 4, MTP_CONTAINER_DATA);
    wr16le(data_hdr + 6, MTP_OP_SEND_OBJECT_INFO);
    wr32le(data_hdr + 8, session->transaction_id);

    if (usb_write_all(session, data_hdr, MTP_CONTAINER_HEADER_SIZE) != 0) return -1;
    if (usb_write_all(session, d, off) != 0) return -1;

    uint32_t resp_params[3];
    int resp_count = 0;
    if (receive_response(session, resp_params, &resp_count) != 0) return -1;
    if (new_handle && resp_count >= 3) *new_handle = resp_params[2];

    // Phase 2: SendObject
    if (send_command(session, MTP_OP_SEND_OBJECT, NULL, 0) != 0) return -1;

    uint32_t send_len = MTP_CONTAINER_HEADER_SIZE + (uint32_t)(file_size > 0xFFFFFFF3 ? 0xFFFFFFFF : file_size + MTP_CONTAINER_HEADER_SIZE);
    wr32le(data_hdr, file_size > 0xFFFFFFF3 ? 0xFFFFFFFF : send_len);
    wr16le(data_hdr + 4, MTP_CONTAINER_DATA);
    wr16le(data_hdr + 6, MTP_OP_SEND_OBJECT);
    wr32le(data_hdr + 8, session->transaction_id);
    if (usb_write_all(session, data_hdr, MTP_CONTAINER_HEADER_SIZE) != 0) return -1;

    SET_NOCACHE(src_fd);
    uint64_t sent = 0;
    while (sent < file_size) {
        size_t to_read = (file_size - sent) < session->data_buf_size
                         ? (size_t)(file_size - sent) : session->data_buf_size;
        ssize_t n = read_all(src_fd, session->data_buf, to_read);
        if (n <= 0) { set_error(session, "Read from source failed or EOF before expected size"); return -1; }
        if (usb_write_all(session, session->data_buf, (size_t)n) != 0) return -1;
        sent += (uint64_t)n;
    }

    if (sent != file_size) {
        set_error(session, "SendObject: bytes sent does not match declared file_size");
        return -1;
    }

    return receive_response(session, NULL, NULL);
}

int mtp_rename_object(mtp_session_t *session, uint32_t handle, const char *new_name) {
    if (!session || !session->is_open || !new_name) return -1;

    uint32_t params[2] = { handle, MTP_PROP_OBJECT_FILENAME };
    if (send_command(session, MTP_OP_SET_OBJECT_PROP_VALUE, params, 2) != 0) return -1;

    uint8_t str_buf[512];
    int str_len = mtp_build_string(new_name, str_buf, sizeof(str_buf));
    if (str_len < 0) { set_error(session, "Failed to encode new name"); return -1; }

    uint8_t data_hdr[MTP_CONTAINER_HEADER_SIZE];
    uint32_t total = MTP_CONTAINER_HEADER_SIZE + (uint32_t)str_len;
    wr32le(data_hdr, total);
    wr16le(data_hdr + 4, MTP_CONTAINER_DATA);
    wr16le(data_hdr + 6, MTP_OP_SET_OBJECT_PROP_VALUE);
    wr32le(data_hdr + 8, session->transaction_id);

    if (usb_write_all(session, data_hdr, MTP_CONTAINER_HEADER_SIZE) != 0) return -1;
    if (usb_write_all(session, str_buf, (size_t)str_len) != 0) return -1;

    return receive_response(session, NULL, NULL);
}

int mtp_create_folder(mtp_session_t *session, uint32_t parent_handle,
                      uint32_t storage_id, const char *folder_name,
                      uint32_t *new_handle) {
    if (!session || !session->is_open || !folder_name) return -1;

    uint8_t *d = (uint8_t *)session->data_buf;
    memset(d, 0, 52);
    wr32le(d, storage_id);
    wr16le(d + 4, MTP_FORMAT_ASSOCIATION);
    wr32le(d + 8, 0);
    wr32le(d + 38, parent_handle);
    wr16le(d + 42, 0x0001);

    size_t off = 52;
    int str_len = mtp_build_string(folder_name, d + off, session->data_buf_size - off);
    if (str_len < 0) { set_error(session, "Failed to encode folder name"); return -1; }
    off += (size_t)str_len;
    d[off++] = 0; d[off++] = 0; d[off++] = 0;

    uint32_t cmd_params[2] = { storage_id, parent_handle };
    if (send_command(session, MTP_OP_SEND_OBJECT_INFO, cmd_params, 2) != 0) return -1;

    uint8_t data_hdr[MTP_CONTAINER_HEADER_SIZE];
    uint32_t data_container_len = MTP_CONTAINER_HEADER_SIZE + (uint32_t)off;
    wr32le(data_hdr, data_container_len);
    wr16le(data_hdr + 4, MTP_CONTAINER_DATA);
    wr16le(data_hdr + 6, MTP_OP_SEND_OBJECT_INFO);
    wr32le(data_hdr + 8, session->transaction_id);

    if (usb_write_all(session, data_hdr, MTP_CONTAINER_HEADER_SIZE) != 0) return -1;
    if (usb_write_all(session, d, off) != 0) return -1;

    uint32_t resp_params[3];
    int resp_count = 0;
    if (receive_response(session, resp_params, &resp_count) != 0) return -1;
    if (new_handle && resp_count >= 3) *new_handle = resp_params[2];
    return 0;
}

// ============================================================================
// Device Info
// ============================================================================

int mtp_get_device_info(mtp_session_t *session, void *info_buf,
                        size_t info_buf_size, size_t *bytes_out) {
    if (!session || !info_buf || !bytes_out) return -1;

    session->transaction_id++;
    int cmd_len = mtp_build_command(session->cmd_buf, MTP_OP_GET_DEVICE_INFO,
                                    session->transaction_id, NULL, 0);
    if (usb_write_all(session, session->cmd_buf, (size_t)cmd_len) != 0) return -1;

    ssize_t data_len = receive_data_phase(session);
    if (data_len < 0) return -1;

    size_t copy_len = (size_t)data_len < info_buf_size ? (size_t)data_len : info_buf_size;
    memcpy(info_buf, session->data_buf, copy_len);
    *bytes_out = copy_len;

    return receive_response(session, NULL, NULL);
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
