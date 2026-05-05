// CTransferUtils — High-performance C utilities for SnapHaul
// Copyright (c) 2026 SnapHaul Contributors
// Licensed under GPL-3.0

#ifndef TRANSFER_UTILS_H
#define TRANSFER_UTILS_H

#include <stdint.h>
#include <stddef.h>

// MARK: - Fast File Copy with F_NOCACHE

/// Copy a file using direct I/O (F_NOCACHE) with page-aligned buffers.
/// Bypasses the macOS unified buffer cache entirely — write-once data
/// doesn't pollute the cache, freeing ~200-500 MB for other apps.
///
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
    int64_t mod_time;       // Unix timestamp
    int is_directory;
    int is_symlink;
} ls_entry_t;

/// Parse `ls -la` output into an array of entries.
/// Uses zero-copy pointer arithmetic — no heap allocations per line.
///
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

/// Suppress Spotlight indexing on a file (set backup-exclude xattr).
/// @return 0 on success, -1 on error
int suppress_spotlight(const char *path);

/// Re-enable Spotlight indexing on a file (remove backup-exclude xattr).
/// @return 0 on success, -1 on error
int enable_spotlight(const char *path);

#endif // TRANSFER_UTILS_H
