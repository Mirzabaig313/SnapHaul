// CTransferUtils — High-performance C utilities for SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0

#ifndef TRANSFER_UTILS_H
#define TRANSFER_UTILS_H

#include <stdint.h>
#include <stddef.h>

// MARK: - Fast File Copy with F_NOCACHE

/// Copy a file using direct I/O (F_NOCACHE) with page-aligned buffers.
/// @param src_path Source file path
/// @param dst_path Destination file path (created or overwritten)
/// @param chunk_size Read/write chunk size in bytes (0 = auto: 4 MB)
/// @param bytes_written Output: total bytes written
/// @return 0 on success, -1 on error (check errno)
int fast_copy_nocache(
    const char *src_path,
    const char *dst_path,
    size_t chunk_size,
    uint64_t *bytes_written
);

// MARK: - Fast ls -la Parser

/// Parsed file entry from `ls -la` output.
typedef struct {
    char name[1024];
    char path[2048];
    uint64_t size;
    int64_t mod_time;
    int is_directory;
    int is_symlink;
} ls_entry_t;

/// Parse `ls -la` output into an array of entries.
/// @param output Raw `ls -la` output string
/// @param parent_path Parent directory path (prepended to names)
/// @param entries Output array (caller-allocated)
/// @param max_entries Maximum entries to parse
/// @return Number of entries parsed
int parse_ls_output(
    const char *output,
    const char *parent_path,
    ls_entry_t *entries,
    int max_entries
);

// MARK: - Spotlight Indexing Control

int suppress_spotlight(const char *path);
int enable_spotlight(const char *path);

// MARK: - XXH3 Hashing (ARM NEON optimized)

/// Hash a file using XXH3-64. Memory-maps the file for zero-copy hashing.
/// @param path File path to hash
/// @param hash_out Output: 64-bit hash value
/// @return 0 on success, -1 on error
int xxh3_hash_file(const char *path, uint64_t *hash_out);

/// Hash a memory buffer using XXH3-64.
/// @param data Pointer to data
/// @param length Data length in bytes
/// @return 64-bit hash value
uint64_t xxh3_hash_buffer(const void *data, size_t length);

/// Format a 64-bit hash as a 16-character hex string.
/// @param hash The hash value
/// @param out Output buffer (must be at least 17 bytes)
void xxh3_format_hex(uint64_t hash, char *out);

// MARK: - Fast EXIF Date Extraction

/// Result of EXIF date extraction.
typedef struct {
    int year;
    int month;
    int day;
    int hour;
    int minute;
    int second;
    int valid;          // 1 if date was found, 0 otherwise
} exif_date_t;

/// Extract DateTimeOriginal from a JPEG/TIFF/DNG file without loading full EXIF.
/// Reads only the minimum bytes needed to locate the tag (~4-8 KB typically).
/// @param path File path
/// @param date_out Output: extracted date
/// @return 0 on success, -1 if date not found or file unreadable
int fast_exif_date(const char *path, exif_date_t *date_out);

// MARK: - ADB Output Tokenizer

/// Parsed result from `adb pull` output.
typedef struct {
    uint64_t bytes_transferred;
    double speed_mbps;
    double duration_secs;
    int files_pulled;
    int files_skipped;
} adb_pull_result_t;

/// Parse `adb pull` output to extract transfer statistics.
/// @param output Raw adb output string
/// @param result Output: parsed statistics
/// @return 0 on success, -1 if parsing failed
int parse_adb_pull_output(const char *output, adb_pull_result_t *result);

/// Parsed result from `adb devices -l` output.
typedef struct {
    char serial[64];
    char status[32];    // "device", "unauthorized", "offline"
    char model[128];
} adb_device_t;

/// Parse `adb devices -l` output into device entries.
/// @param output Raw adb output string
/// @param devices Output array (caller-allocated)
/// @param max_devices Maximum devices to parse
/// @return Number of devices parsed
int parse_adb_devices(const char *output, adb_device_t *devices, int max_devices);

/// Parse `df` output to extract storage info.
/// @param output Raw df output string
/// @param total_bytes Output: total storage in bytes
/// @param free_bytes Output: free storage in bytes
/// @return 0 on success, -1 if parsing failed
int parse_df_output(const char *output, uint64_t *total_bytes, uint64_t *free_bytes);

#endif // TRANSFER_UTILS_H
