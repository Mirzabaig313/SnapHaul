// CTransferUtils — High-performance C utilities for SnapHaul
// Copyright (c) 2026 SnapHaul Contributors — GPL-3.0

#include "include/transfer_utils.h"
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <sys/xattr.h>
#include <time.h>
#include <errno.h>

// ============================================================================
// Fast File Copy
// ============================================================================

static const size_t DEFAULT_CHUNK = 4 * 1024 * 1024;
static const size_t PAGE_ALIGN = 16384;

int fast_copy_nocache(
    const char *src_path,
    const char *dst_path,
    size_t chunk_size,
    uint64_t *bytes_written
) {
    if (!src_path || !dst_path || !bytes_written) {
        errno = EINVAL;
        return -1;
    }

    *bytes_written = 0;
    if (chunk_size == 0) chunk_size = DEFAULT_CHUNK;
    chunk_size = (chunk_size + PAGE_ALIGN - 1) & ~(PAGE_ALIGN - 1);

    int src_fd = open(src_path, O_RDONLY);
    if (src_fd < 0) return -1;
    fcntl(src_fd, F_NOCACHE, 1);

    struct stat st;
    if (fstat(src_fd, &st) < 0) { close(src_fd); return -1; }

    int dst_fd = open(dst_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (dst_fd < 0) { close(src_fd); return -1; }
    fcntl(dst_fd, F_NOCACHE, 1);

    // Pre-allocate for reduced fragmentation
    if (st.st_size > 0) {
        fstore_t fst = {
            .fst_flags = F_ALLOCATECONTIG | F_ALLOCATEALL,
            .fst_posmode = F_PEOFPOSMODE,
            .fst_offset = 0,
            .fst_length = st.st_size
        };
        if (fcntl(dst_fd, F_PREALLOCATE, &fst) < 0) {
            fst.fst_flags = F_ALLOCATEALL;
            fcntl(dst_fd, F_PREALLOCATE, &fst);
        }
    }

    void *buf = NULL;
    if (posix_memalign(&buf, PAGE_ALIGN, chunk_size) != 0) {
        close(src_fd); close(dst_fd);
        errno = ENOMEM;
        return -1;
    }

    ssize_t bytes_read;
    while ((bytes_read = read(src_fd, buf, chunk_size)) > 0) {
        ssize_t written = 0;
        while (written < bytes_read) {
            ssize_t w = write(dst_fd, (char *)buf + written, bytes_read - written);
            if (w < 0) {
                if (errno == EINTR) continue;
                free(buf); close(src_fd); close(dst_fd);
                return -1;
            }
            written += w;
        }
        *bytes_written += (uint64_t)written;
    }

    free(buf);
    ftruncate(dst_fd, (off_t)*bytes_written);
    fcntl(dst_fd, F_FULLFSYNC);
    close(src_fd);
    close(dst_fd);

    return (bytes_read < 0) ? -1 : 0;
}

// ============================================================================
// ls -la Parser
// ============================================================================

static int64_t parse_ls_date(const char *date_str, const char *time_str) {
    if (date_str[4] != '-' || date_str[7] != '-') return 0;
    if (time_str[2] != ':') return 0;

    struct tm tm = {0};
    tm.tm_year = (date_str[0]-'0')*1000 + (date_str[1]-'0')*100 +
                 (date_str[2]-'0')*10 + (date_str[3]-'0') - 1900;
    tm.tm_mon  = (date_str[5]-'0')*10 + (date_str[6]-'0') - 1;
    tm.tm_mday = (date_str[8]-'0')*10 + (date_str[9]-'0');
    tm.tm_hour = (time_str[0]-'0')*10 + (time_str[1]-'0');
    tm.tm_min  = (time_str[3]-'0')*10 + (time_str[4]-'0');
    return (int64_t)mktime(&tm);
}

int parse_ls_output(
    const char *output, const char *parent_path,
    ls_entry_t *entries, int max_entries
) {
    if (!output || !parent_path || !entries || max_entries <= 0) return 0;

    int count = 0;
    const char *line = output;

    size_t parent_len = strlen(parent_path);
    char clean_parent[2048];
    strncpy(clean_parent, parent_path, sizeof(clean_parent) - 1);
    clean_parent[sizeof(clean_parent) - 1] = '\0';
    if (parent_len > 1 && clean_parent[parent_len - 1] == '/')
        clean_parent[--parent_len] = '\0';

    while (*line && count < max_entries) {
        const char *eol = strchr(line, '\n');
        size_t line_len = eol ? (size_t)(eol - line) : strlen(line);

        if (line_len < 10 || line[0] == 't' ||
            (line_len > 2 && line[0] == 'l' && line[1] == 's' && line[2] == ':')) {
            line = eol ? eol + 1 : line + line_len;
            continue;
        }

        int is_dir = (line[0] == 'd');
        int is_link = (line[0] == 'l');

        const char *p = line;
        for (int f = 0; f < 4 && p < line + line_len; f++) {
            while (p < line + line_len && *p != ' ') p++;
            while (p < line + line_len && *p == ' ') p++;
        }
        if (p >= line + line_len) goto next;

        uint64_t size = 0;
        while (p < line + line_len && *p >= '0' && *p <= '9') {
            size = size * 10 + (*p - '0');
            p++;
        }
        while (p < line + line_len && *p == ' ') p++;

        const char *date_start = p;
        while (p < line + line_len && *p != ' ') p++;
        while (p < line + line_len && *p == ' ') p++;

        const char *time_start = p;
        while (p < line + line_len && *p != ' ') p++;
        while (p < line + line_len && *p == ' ') p++;

        const char *name_start = p;
        size_t name_len = line_len - (size_t)(name_start - line);

        while (name_len > 0 && (name_start[name_len-1] <= ' ')) name_len--;
        if (name_len == 0 || name_len >= sizeof(entries[0].name)) goto next;

        if ((name_len == 1 && name_start[0] == '.') ||
            (name_len == 2 && name_start[0] == '.' && name_start[1] == '.'))
            goto next;

        size_t actual_len = name_len;
        if (is_link) {
            for (size_t j = 0; j + 3 < name_len; j++) {
                if (name_start[j]==' ' && name_start[j+1]=='-' &&
                    name_start[j+2]=='>' && name_start[j+3]==' ') {
                    actual_len = j;
                    break;
                }
            }
        }

        ls_entry_t *e = &entries[count];
        memcpy(e->name, name_start, actual_len);
        e->name[actual_len] = '\0';
        snprintf(e->path, sizeof(e->path), "%s/%s", clean_parent, e->name);
        e->size = (is_dir || is_link) ? 0 : size;
        e->mod_time = parse_ls_date(date_start, time_start);
        e->is_directory = is_dir || is_link;
        e->is_symlink = is_link;
        count++;

next:
        line = eol ? eol + 1 : line + line_len;
    }
    return count;
}

// ============================================================================
// Spotlight Control
// ============================================================================

static const char *SPOTLIGHT_XATTR = "com.apple.metadata:com_apple_backup_excludeItem";

int suppress_spotlight(const char *path) {
    uint8_t flag = 1;
    return setxattr(path, SPOTLIGHT_XATTR, &flag, 1, 0, 0);
}

int enable_spotlight(const char *path) {
    int r = removexattr(path, SPOTLIGHT_XATTR, 0);
    return (r < 0 && errno == ENOATTR) ? 0 : r;
}

// ============================================================================
// XXH3-64 Hashing
// ============================================================================

static const uint64_t P1 = 0x9E3779B185EBCA87ULL;
static const uint64_t P2 = 0xC2B2AE3D27D4EB4FULL;
static const uint64_t P3 = 0x165667B19E3779F9ULL;
static const uint64_t P4 = 0x85EBCA77C2B2AE63ULL;
static const uint64_t P5 = 0x27D4EB2F165667C5ULL;

static inline uint64_t rotl64(uint64_t x, int r) {
    return (x << r) | (x >> (64 - r));
}

static inline uint64_t mix(uint64_t h, uint64_t v) {
    h ^= v;
    h ^= rotl64(h, 49) ^ rotl64(h, 24);
    h *= 0x9FB21C651E98DF25ULL;
    h ^= (h >> 35) + 8;
    h *= 0x9FB21C651E98DF25ULL;
    h ^= (h >> 28);
    return h;
}

static inline uint64_t rd64(const uint8_t *p) {
    uint64_t v; memcpy(&v, p, 8); return v;
}

uint64_t xxh3_hash_buffer(const void *data, size_t len) {
    if (!data || len == 0) return P5;

    const uint8_t *p = (const uint8_t *)data;
    uint64_t h = P5 + (uint64_t)len;

    if (len < 8) {
        for (size_t i = 0; i < len; i++) {
            h ^= (uint64_t)p[i] * P1;
            h = rotl64(h, 11) * P4;
        }
        return mix(h, P2);
    }

    if (len >= 32) {
        uint64_t v1 = h + P1 + P2, v2 = h + P2, v3 = h, v4 = h - P1;
        size_t blocks = len / 32;
        for (size_t i = 0; i < blocks; i++) {
            v1 += rd64(p) * P2; v1 = rotl64(v1, 31) * P1; p += 8;
            v2 += rd64(p) * P2; v2 = rotl64(v2, 31) * P1; p += 8;
            v3 += rd64(p) * P2; v3 = rotl64(v3, 31) * P1; p += 8;
            v4 += rd64(p) * P2; v4 = rotl64(v4, 31) * P1; p += 8;
        }
        h = rotl64(v1,1) + rotl64(v2,7) + rotl64(v3,12) + rotl64(v4,18);
        h = mix(h, v1); h = mix(h, v2); h = mix(h, v3); h = mix(h, v4);
        h += (uint64_t)len;
        len -= blocks * 32;
    }

    while (len >= 8) {
        h ^= rd64(p) * P2;
        h = rotl64(h, 27) * P1 + P4;
        p += 8; len -= 8;
    }
    while (len > 0) {
        h ^= (uint64_t)(*p) * P5;
        h = rotl64(h, 11) * P1;
        p++; len--;
    }

    h ^= h >> 33; h *= P2;
    h ^= h >> 29; h *= P3;
    h ^= h >> 32;
    return h;
}

int xxh3_hash_file(const char *path, uint64_t *hash_out) {
    if (!path || !hash_out) { errno = EINVAL; return -1; }

    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;

    struct stat st;
    if (fstat(fd, &st) < 0) { close(fd); return -1; }

    if (st.st_size == 0) {
        close(fd);
        *hash_out = P5;
        return 0;
    }

    void *mapped = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED) return -1;

    madvise(mapped, (size_t)st.st_size, MADV_SEQUENTIAL);
    *hash_out = xxh3_hash_buffer(mapped, (size_t)st.st_size);
    munmap(mapped, (size_t)st.st_size);
    return 0;
}

void xxh3_format_hex(uint64_t hash, char *out) {
    snprintf(out, 17, "%016llx", (unsigned long long)hash);
}

// ============================================================================
// EXIF Date Extraction
// ============================================================================

static const uint16_t TAG_DATETIME_ORIGINAL = 0x9003;
static const uint16_t TAG_DATETIME = 0x0132;
static const uint16_t TAG_EXIF_IFD = 0x8769;
static const int MAX_IFD_DEPTH = 4;

static inline uint16_t r16(const uint8_t *p, int be) {
    return be ? ((uint16_t)p[0]<<8)|p[1] : ((uint16_t)p[1]<<8)|p[0];
}
static inline uint32_t r32(const uint8_t *p, int be) {
    return be ? ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3]
              : ((uint32_t)p[3]<<24)|((uint32_t)p[2]<<16)|((uint32_t)p[1]<<8)|p[0];
}

static int parse_exif_datestr(const char *s, size_t avail, exif_date_t *out) {
    if (avail < 19) return -1;
    if (s[4]!=':' || s[7]!=':' || s[10]!=' ' || s[13]!=':' || s[16]!=':') return -1;

    out->year   = (s[0]-'0')*1000 + (s[1]-'0')*100 + (s[2]-'0')*10 + (s[3]-'0');
    out->month  = (s[5]-'0')*10 + (s[6]-'0');
    out->day    = (s[8]-'0')*10 + (s[9]-'0');
    out->hour   = (s[11]-'0')*10 + (s[12]-'0');
    out->minute = (s[14]-'0')*10 + (s[15]-'0');
    out->second = (s[17]-'0')*10 + (s[18]-'0');
    out->valid  = 1;
    return 0;
}

static int search_ifd(const uint8_t *base, size_t size,
                      uint32_t offset, int be, int depth, exif_date_t *out) {
    if (depth > MAX_IFD_DEPTH) return -1;
    if (offset + 2 > size) return -1;

    uint16_t n = r16(base + offset, be);
    uint32_t start = offset + 2;

    for (uint16_t i = 0; i < n; i++) {
        uint32_t pos = start + (uint32_t)i * 12;
        if (pos + 12 > size) break;

        uint16_t tag = r16(base + pos, be);

        if (tag == TAG_DATETIME_ORIGINAL || tag == TAG_DATETIME) {
            uint32_t count = r32(base + pos + 4, be);
            uint32_t val_off = r32(base + pos + 8, be);
            size_t avail = (val_off < size) ? size - val_off : 0;
            if (count >= 19 && avail >= 19) {
                if (parse_exif_datestr((const char *)(base + val_off), avail, out) == 0)
                    return 0;
            }
        }

        if (tag == TAG_EXIF_IFD) {
            uint32_t sub = r32(base + pos + 8, be);
            if (search_ifd(base, size, sub, be, depth + 1, out) == 0)
                return 0;
        }
    }
    return -1;
}

int fast_exif_date(const char *path, exif_date_t *date_out) {
    if (!path || !date_out) return -1;
    memset(date_out, 0, sizeof(exif_date_t));

    int fd = open(path, O_RDONLY);
    if (fd < 0) return -1;

    static const size_t BUF_SIZE = 65536;
    uint8_t *buf = malloc(BUF_SIZE);
    if (!buf) { close(fd); return -1; }

    ssize_t n = read(fd, buf, BUF_SIZE);
    close(fd);
    if (n < 12) { free(buf); return -1; }
    size_t buf_len = (size_t)n;

    const uint8_t *tiff = NULL;
    size_t tiff_len = 0;

    if (buf[0] == 0xFF && buf[1] == 0xD8) {
        // JPEG: find APP1 (EXIF)
        size_t pos = 2;
        while (pos + 4 < buf_len) {
            if (buf[pos] != 0xFF) break;
            uint8_t marker = buf[pos + 1];
            uint16_t seg_len = ((uint16_t)buf[pos+2] << 8) | buf[pos+3];
            if (marker == 0xE1 && pos + 10 < buf_len &&
                buf[pos+4]=='E' && buf[pos+5]=='x' &&
                buf[pos+6]=='i' && buf[pos+7]=='f') {
                tiff = buf + pos + 10;
                tiff_len = buf_len - (pos + 10);
                break;
            }
            pos += 2 + seg_len;
        }
    } else if ((buf[0]=='I' && buf[1]=='I') || (buf[0]=='M' && buf[1]=='M')) {
        tiff = buf;
        tiff_len = buf_len;
    }

    if (!tiff || tiff_len < 8) { free(buf); return -1; }

    int be = (tiff[0] == 'M');
    uint32_t ifd0 = r32(tiff + 4, be);
    int result = search_ifd(tiff, tiff_len, ifd0, be, 0, date_out);
    free(buf);
    return result;
}

// ============================================================================
// ADB Output Tokenizer
// ============================================================================

int parse_adb_pull_output(const char *output, adb_pull_result_t *result) {
    if (!output || !result) return -1;
    memset(result, 0, sizeof(adb_pull_result_t));

    const char *pulled = strstr(output, " pulled");
    if (pulled && pulled > output) {
        const char *p = pulled - 1;
        while (p > output && *p == ' ') p--;
        while (p > output && p[-1] >= '0' && p[-1] <= '9') p--;
        if (*p >= '0' && *p <= '9')
            result->files_pulled = atoi(p);
    }

    const char *skipped = strstr(output, " skipped");
    if (skipped && skipped > output) {
        const char *p = skipped - 1;
        while (p > output && *p == ' ') p--;
        while (p > output && p[-1] >= '0' && p[-1] <= '9') p--;
        if (*p >= '0' && *p <= '9')
            result->files_skipped = atoi(p);
    }

    const char *paren = strstr(output, "(");
    if (paren) {
        result->bytes_transferred = strtoull(paren + 1, NULL, 10);
        const char *in_str = strstr(paren, " bytes in ");
        if (in_str) {
            result->duration_secs = strtod(in_str + 10, NULL);
            if (result->duration_secs > 0.0)
                result->speed_mbps = (double)result->bytes_transferred /
                                     result->duration_secs / 1000000.0;
        }
    }

    return (result->bytes_transferred > 0 || result->files_pulled > 0) ? 0 : -1;
}

int parse_adb_devices(const char *output, adb_device_t *devices, int max_devices) {
    if (!output || !devices || max_devices <= 0) return 0;

    int count = 0;
    const char *line = output;

    while (*line && count < max_devices) {
        const char *eol = strchr(line, '\n');
        size_t len = eol ? (size_t)(eol - line) : strlen(line);

        if (len < 5 || line[0] == '*' || (len >= 4 && strncmp(line, "List", 4) == 0)) {
            line = eol ? eol + 1 : line + len;
            continue;
        }

        adb_device_t *d = &devices[count];
        memset(d, 0, sizeof(adb_device_t));

        const char *p = line;
        size_t slen = 0;
        while (slen < len && p[slen] != ' ' && p[slen] != '\t') slen++;
        if (slen == 0 || slen >= sizeof(d->serial)) goto skip;
        memcpy(d->serial, p, slen);

        p += slen;
        while (p < line + len && (*p == ' ' || *p == '\t')) p++;

        size_t stlen = 0;
        while (p + stlen < line + len && p[stlen] != ' ' && p[stlen] != '\t') stlen++;
        if (stlen >= sizeof(d->status)) stlen = sizeof(d->status) - 1;
        memcpy(d->status, p, stlen);

        const char *mk = strstr(p, "model:");
        if (mk && mk < line + len) {
            mk += 6;
            size_t ml = 0;
            while (mk + ml < line + len && mk[ml] != ' ' && mk[ml] != '\n') ml++;
            if (ml >= sizeof(d->model)) ml = sizeof(d->model) - 1;
            memcpy(d->model, mk, ml);
        }

        count++;
skip:
        line = eol ? eol + 1 : line + len;
    }
    return count;
}

int parse_df_output(const char *output, uint64_t *total_bytes, uint64_t *free_bytes) {
    if (!output || !total_bytes || !free_bytes) return -1;
    *total_bytes = 0;
    *free_bytes = 0;

    const char *line = output;
    const char *data_line = NULL;

    while (*line) {
        const char *eol = strchr(line, '\n');
        size_t len = eol ? (size_t)(eol - line) : strlen(line);

        // Skip header line and empty lines
        if (len > 5 && !(len >= 10 && strncmp(line, "Filesystem", 10) == 0) &&
            line[0] != '\r' && line[0] != '\n') {
            data_line = line;
        }
        line = eol ? eol + 1 : line + len;
        if (!eol) break;
    }
    if (!data_line) return -1;

    const char *p = data_line;
    while (*p && *p != ' ' && *p != '\t') p++;
    while (*p == ' ' || *p == '\t') p++;

    uint64_t total_kb = strtoull(p, NULL, 10);
    while (*p && *p != ' ' && *p != '\t') p++;
    while (*p == ' ' || *p == '\t') p++;
    while (*p && *p != ' ' && *p != '\t') p++;  // skip "used"
    while (*p == ' ' || *p == '\t') p++;

    uint64_t free_kb = strtoull(p, NULL, 10);

    *total_bytes = total_kb * 1024;
    *free_bytes = free_kb * 1024;
    return (total_kb > 0) ? 0 : -1;
}
