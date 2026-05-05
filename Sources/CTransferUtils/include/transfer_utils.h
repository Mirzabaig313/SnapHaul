// CTransferUtils — High-performance C utilities for SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0

#ifndef TRANSFER_UTILS_H
#define TRANSFER_UTILS_H

#include <stdint.h>
#include <stddef.h>

// MARK: - Fast File Copy with F_NOCACHE

/// Copy a file using direct I/O (F_NOCACHE) with page-aligned buffers.
/// Uses double-buffering for overlapped read/write when possible.
/// Skips F_PREALLOCATE for files < 1 MB to avoid syscall overhead.
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

/// Copy a file with progress callback for multi-destination copy.
/// Same as fast_copy_nocache but calls progress_fn every chunk.
/// @param src_path Source file path
/// @param dst_path Destination file path
/// @param chunk_size Chunk size (0 = auto)
/// @param bytes_written Output: total bytes written
/// @param progress_fn Callback with bytes written so far (NULL to skip)
/// @param context Opaque pointer passed to progress_fn
/// @return 0 on success, -1 on error
int fast_copy_with_progress(
    const char *src_path,
    const char *dst_path,
    size_t chunk_size,
    uint64_t *bytes_written,
    void (*progress_fn)(uint64_t bytes_so_far, void *context),
    void *context
);

/// Copy a file to multiple destinations simultaneously using all cores.
/// Primary destination is written first, then additional copies run in parallel.
/// @param src_path Source file path
/// @param dst_paths Array of destination paths
/// @param dst_count Number of destinations
/// @param chunk_size Chunk size (0 = auto)
/// @param results Output array: 0 = success, -1 = failure per destination (caller-allocated)
/// @return Number of successful copies
int fast_copy_multi_destination(
    const char *src_path,
    const char **dst_paths,
    int dst_count,
    size_t chunk_size,
    int *results
);

// MARK: - Fast ls -la Parser

/// Parsed file entry from `ls -la` output.
/// Uses 256+512 byte fields (768 bytes/entry) instead of 1024+2048 (3 KB/entry).
/// 1000 entries = ~768 KB instead of ~3 MB. Android paths rarely exceed 256 chars.
typedef struct {
    char name[256];
    char path[512];
    uint64_t size;
    int64_t mod_time;
    int is_directory;
    int is_symlink;
} ls_entry_t;

/// Parse `ls -la` output into an array of entries.
/// Uses fast timestamp computation (no mktime) and direct memcpy path construction.
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

/// Batch suppress Spotlight for multiple paths.
/// @param paths Array of path strings
/// @param count Number of paths
/// @return Number of paths successfully suppressed
int suppress_spotlight_batch(const char **paths, int count);

/// Batch enable Spotlight for multiple paths.
/// @param paths Array of path strings
/// @param count Number of paths
/// @return Number of paths successfully enabled
int enable_spotlight_batch(const char **paths, int count);

// MARK: - XXH3 Hashing (ARM NEON optimized)

/// Hash a file using XXH3-64. Memory-maps the file for zero-copy hashing.
/// Uses MADV_DONTNEED after hashing to prevent page cache pollution.
/// For files > 256 MB, uses chunked mmap to reduce TLB pressure.
/// @param path File path to hash
/// @param hash_out Output: 64-bit hash value
/// @return 0 on success, -1 on error
int xxh3_hash_file(const char *path, uint64_t *hash_out);

/// Hash a memory buffer using XXH3-64.
/// Uses ARM NEON vectorization on Apple Silicon for 2x throughput.
/// @param data Pointer to data
/// @param length Data length in bytes
/// @return 64-bit hash value
uint64_t xxh3_hash_buffer(const void *data, size_t length);

/// Format a 64-bit hash as a 16-character hex string.
/// @param hash The hash value
/// @param out Output buffer (must be at least 17 bytes)
void xxh3_format_hex(uint64_t hash, char *out);

/// Batch hash multiple files. Avoids per-file Swift/C boundary crossing.
/// @param paths Array of file path strings
/// @param hashes Output array of hash values (caller-allocated, same count as paths)
/// @param count Number of files to hash
/// @return Number of files successfully hashed (-1 on invalid args)
int xxh3_hash_files_batch(const char **paths, uint64_t *hashes, int count);

/// Parallel batch hash using all available cores via GCD dispatch_apply.
/// Each file is hashed on a separate core. Ideal for 50+ files.
/// @param paths Array of file path strings
/// @param hashes Output array of hash values (caller-allocated)
/// @param count Number of files to hash
/// @return Number of files successfully hashed (-1 on invalid args)
int xxh3_hash_files_parallel(const char **paths, uint64_t *hashes, int count);

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
/// Prefers TAG_DATETIME_ORIGINAL over TAG_DATETIME for correctness.
/// Uses stack-allocated buffer to avoid malloc overhead in batch processing.
/// @param path File path
/// @param date_out Output: extracted date
/// @return 0 on success, -1 if date not found or file unreadable
int fast_exif_date(const char *path, exif_date_t *date_out);

/// Batch extract EXIF dates from multiple files.
/// @param paths Array of file path strings
/// @param dates Output array of exif_date_t (caller-allocated)
/// @param count Number of files
/// @return Number of files with valid dates extracted
int fast_exif_date_batch(const char **paths, exif_date_t *dates, int count);

/// Parallel batch EXIF extraction using all available cores.
/// @param paths Array of file path strings
/// @param dates Output array of exif_date_t (caller-allocated)
/// @param count Number of files
/// @return Number of files with valid dates extracted
int fast_exif_date_parallel(const char **paths, exif_date_t *dates, int count);

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

// MARK: - Buffer Pool

/// Opaque buffer pool handle (void* for Swift interop with incomplete C struct).
/// Create with buffer_pool_create, destroy with buffer_pool_destroy.

/// Create a buffer pool with pre-allocated page-aligned buffers.
/// @param buffer_size Size of each buffer in bytes (rounded up to page alignment)
/// @param count Number of buffers to pre-allocate (typically 4)
/// @return Pool handle (void*), or NULL on failure
void *buffer_pool_create(size_t buffer_size, int count);

/// Acquire a buffer from the pool. Returns NULL if all buffers are in use.
/// @param pool The buffer pool handle
/// @return Pointer to a page-aligned buffer, or NULL
void *buffer_pool_acquire(void *pool);

/// Release a buffer back to the pool.
/// @param pool The buffer pool handle
/// @param buf The buffer to release (must have been acquired from this pool)
void buffer_pool_release(void *pool, void *buf);

/// Destroy the pool and free all buffers.
/// @param pool The buffer pool handle
void buffer_pool_destroy(void *pool);

#endif // TRANSFER_UTILS_H
