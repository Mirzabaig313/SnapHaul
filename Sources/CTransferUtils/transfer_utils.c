// CTransferUtils — High-performance C utilities for SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0

#include "include/transfer_utils.h"
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <time.h>
#include <errno.h>

// MARK: - Fast File Copy with F_NOCACHE

static const size_t DEFAULT_CHUNK = 4 * 1024 * 1024;  // 4 MB
static const size_t PAGE_SIZE_ALIGN = 16384;           // 16 KB (Apple Silicon page size)

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

    // Align chunk size to page boundary for optimal DMA
    chunk_size = (chunk_size + PAGE_SIZE_ALIGN - 1) & ~(PAGE_SIZE_ALIGN - 1);

    int src_fd = open(src_path, O_RDONLY);
    if (src_fd < 0) return -1;

    // Set F_NOCACHE on source — we read once, no need to cache
    fcntl(src_fd, F_NOCACHE, 1);

    // Get source file size for pre-allocation
    struct stat st;
    if (fstat(src_fd, &st) < 0) {
        close(src_fd);
        return -1;
    }

    int dst_fd = open(dst_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (dst_fd < 0) {
        close(src_fd);
        return -1;
    }

    // Set F_NOCACHE on destination — write-once data, don't pollute cache
    fcntl(dst_fd, F_NOCACHE, 1);

    // Pre-allocate destination file to avoid fragmentation
    // fstore_t is macOS-specific for contiguous allocation
    fstore_t fst = {
        .fst_flags = F_ALLOCATECONTIG | F_ALLOCATEALL,
        .fst_posmode = F_PEOFPOSMODE,
        .fst_offset = 0,
        .fst_length = st.st_size
    };
    // Try contiguous first, fall back to non-contiguous
    if (fcntl(dst_fd, F_PREALLOCATE, &fst) < 0) {
        fst.fst_flags = F_ALLOCATEALL;
        fcntl(dst_fd, F_PREALLOCATE, &fst);
    }

    // Allocate page-aligned buffer for optimal I/O
    void *buf = NULL;
    if (posix_memalign(&buf, PAGE_SIZE_ALIGN, chunk_size) != 0) {
        close(src_fd);
        close(dst_fd);
        errno = ENOMEM;
        return -1;
    }

    // Copy loop
    ssize_t bytes_read;
    while ((bytes_read = read(src_fd, buf, chunk_size)) > 0) {
        ssize_t total_written = 0;
        while (total_written < bytes_read) {
            ssize_t w = write(dst_fd, (char *)buf + total_written, bytes_read - total_written);
            if (w < 0) {
                if (errno == EINTR) continue;
                free(buf);
                close(src_fd);
                close(dst_fd);
                return -1;
            }
            total_written += w;
        }
        *bytes_written += (uint64_t)total_written;
    }

    free(buf);

    // Truncate to actual size (pre-allocation may have over-allocated)
    ftruncate(dst_fd, (off_t)*bytes_written);

    // Flush to disk
    fcntl(dst_fd, F_FULLFSYNC);

    close(src_fd);
    close(dst_fd);

    return (bytes_read < 0) ? -1 : 0;
}

// MARK: - Fast ls -la Parser

// Parse date fields "YYYY-MM-DD" and "HH:MM" into a Unix timestamp.
// Uses fixed offsets — does not rely on strlen (fields are mid-line).
static int64_t parse_date(const char *date_str, const char *time_str) {
    struct tm tm = {0};

    // Validate minimum expected characters by checking digit positions
    if (date_str[4] != '-' || date_str[7] != '-') return 0;
    if (time_str[2] != ':') return 0;

    tm.tm_year = (date_str[0] - '0') * 1000 + (date_str[1] - '0') * 100 +
                 (date_str[2] - '0') * 10 + (date_str[3] - '0') - 1900;
    tm.tm_mon  = (date_str[5] - '0') * 10 + (date_str[6] - '0') - 1;
    tm.tm_mday = (date_str[8] - '0') * 10 + (date_str[9] - '0');
    tm.tm_hour = (time_str[0] - '0') * 10 + (time_str[1] - '0');
    tm.tm_min  = (time_str[3] - '0') * 10 + (time_str[4] - '0');

    return (int64_t)mktime(&tm);
}

int parse_ls_output(
    const char *output,
    const char *parent_path,
    ls_entry_t *entries,
    int max_entries
) {
    if (!output || !parent_path || !entries || max_entries <= 0) return 0;

    int count = 0;
    const char *line = output;

    // Prepare clean parent path (strip trailing slash)
    size_t parent_len = strlen(parent_path);
    char clean_parent[2048];
    strncpy(clean_parent, parent_path, sizeof(clean_parent) - 1);
    clean_parent[sizeof(clean_parent) - 1] = '\0';
    if (parent_len > 1 && clean_parent[parent_len - 1] == '/') {
        clean_parent[parent_len - 1] = '\0';
        parent_len--;
    }

    while (*line && count < max_entries) {
        // Find end of line
        const char *eol = strchr(line, '\n');
        size_t line_len = eol ? (size_t)(eol - line) : strlen(line);

        // Skip empty lines, "total" lines, and "ls:" error lines
        if (line_len < 10 || line[0] == 't' ||
            (line[0] == 'l' && line[1] == 's' && line[2] == ':')) {
            line = eol ? eol + 1 : line + line_len;
            continue;
        }

        // Parse permissions (field 0)
        int is_dir = (line[0] == 'd');
        int is_link = (line[0] == 'l');

        // Skip to field 4 (size) — skip 4 whitespace-separated fields
        const char *p = line;
        int field = 0;
        while (field < 4 && p < line + line_len) {
            while (p < line + line_len && *p != ' ') p++;
            while (p < line + line_len && *p == ' ') p++;
            field++;
        }
        if (field < 4) goto next_line;

        // Parse size (field 4)
        uint64_t size = 0;
        while (p < line + line_len && *p >= '0' && *p <= '9') {
            size = size * 10 + (*p - '0');
            p++;
        }
        while (p < line + line_len && *p == ' ') p++;

        // Parse date (field 5: "YYYY-MM-DD")
        const char *date_start = p;
        while (p < line + line_len && *p != ' ') p++;
        while (p < line + line_len && *p == ' ') p++;

        // Parse time (field 6: "HH:MM")
        const char *time_start = p;
        while (p < line + line_len && *p != ' ') p++;
        while (p < line + line_len && *p == ' ') p++;

        // Remaining is the filename (field 7+)
        const char *name_start = p;
        size_t name_len = line_len - (size_t)(name_start - line);

        // Trim trailing whitespace
        while (name_len > 0 && (name_start[name_len - 1] == ' ' ||
               name_start[name_len - 1] == '\r' ||
               name_start[name_len - 1] == '\n')) {
            name_len--;
        }

        if (name_len == 0 || name_len >= sizeof(entries[0].name)) goto next_line;

        // Skip . and ..
        if ((name_len == 1 && name_start[0] == '.') ||
            (name_len == 2 && name_start[0] == '.' && name_start[1] == '.')) {
            goto next_line;
        }

        // Strip symlink target: "name -> /target"
        size_t actual_name_len = name_len;
        if (is_link) {
            // Find " -> " in the name (portable, no memmem dependency)
            for (size_t j = 0; j + 3 < name_len; j++) {
                if (name_start[j] == ' ' && name_start[j+1] == '-' &&
                    name_start[j+2] == '>' && name_start[j+3] == ' ') {
                    actual_name_len = j;
                    break;
                }
            }
        }

        // Fill entry
        ls_entry_t *e = &entries[count];
        memcpy(e->name, name_start, actual_name_len);
        e->name[actual_name_len] = '\0';

        snprintf(e->path, sizeof(e->path), "%s/%s", clean_parent, e->name);
        e->size = (is_dir || is_link) ? 0 : size;
        e->mod_time = parse_date(date_start, time_start);
        e->is_directory = is_dir || is_link;
        e->is_symlink = is_link;

        count++;

next_line:
        line = eol ? eol + 1 : line + line_len;
    }

    return count;
}

// MARK: - Spotlight Indexing Control

static const char *SPOTLIGHT_XATTR = "com.apple.metadata:com_apple_backup_excludeItem";

int suppress_spotlight(const char *path) {
    uint8_t flag = 1;
    return setxattr(path, SPOTLIGHT_XATTR, &flag, 1, 0, 0);
}

int enable_spotlight(const char *path) {
    int result = removexattr(path, SPOTLIGHT_XATTR, 0);
    if (result < 0 && errno == ENOATTR) return 0;  // Already removed
    return result;
}
