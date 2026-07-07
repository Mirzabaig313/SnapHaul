// CMTPCore — Native MTP protocol implementation for SnapHaul
// Copyright (c) 2026 SnapHaul Contributors — GPL-3.0
//
// Pure C MTP stack: container framing, operation codes, bulk data transfer.
// Designed to be driven by Swift via IOUSBHostPipe for USB I/O.

#ifndef MTP_CORE_H
#define MTP_CORE_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>

// ============================================================================
// MTP Container Types & Operation Codes
// ============================================================================

// Container types (MTP spec §4.1)
#define MTP_CONTAINER_COMMAND   1
#define MTP_CONTAINER_DATA      2
#define MTP_CONTAINER_RESPONSE  3
#define MTP_CONTAINER_EVENT     4

// Response codes (MTP spec §5.2)
#define MTP_RESP_OK                     0x2001
#define MTP_RESP_GENERAL_ERROR          0x2002
#define MTP_RESP_SESSION_NOT_OPEN       0x2003
#define MTP_RESP_INVALID_TRANSACTION_ID 0x2004
#define MTP_RESP_OPERATION_NOT_SUPPORTED 0x2005
#define MTP_RESP_PARAMETER_NOT_SUPPORTED 0x2006
#define MTP_RESP_INCOMPLETE_TRANSFER    0x2007
#define MTP_RESP_INVALID_STORAGE_ID     0x2008
#define MTP_RESP_INVALID_OBJECT_HANDLE  0x2009
#define MTP_RESP_STORE_FULL             0x200C
#define MTP_RESP_STORE_READ_ONLY        0x200E
#define MTP_RESP_OBJECT_NOT_FOUND       0x2012
#define MTP_RESP_SPEC_BY_FORMAT_UNSUPPORTED 0x2014
#define MTP_RESP_INVALID_PARENT_OBJECT  0x201A
#define MTP_RESP_SESSION_ALREADY_OPEN   0x201E
#define MTP_RESP_TRANSACTION_CANCELLED  0x201F

// Operation codes (MTP spec §5.1)
#define MTP_OP_GET_DEVICE_INFO          0x1001
#define MTP_OP_OPEN_SESSION             0x1002
#define MTP_OP_CLOSE_SESSION            0x1003
#define MTP_OP_GET_STORAGE_IDS          0x1004
#define MTP_OP_GET_STORAGE_INFO         0x1005
#define MTP_OP_GET_NUM_OBJECTS          0x1006
#define MTP_OP_GET_OBJECT_HANDLES       0x1007
#define MTP_OP_GET_OBJECT_INFO          0x1008
#define MTP_OP_GET_OBJECT               0x1009
#define MTP_OP_DELETE_OBJECT            0x100B
#define MTP_OP_SEND_OBJECT_INFO         0x100C
#define MTP_OP_SEND_OBJECT              0x100D
#define MTP_OP_GET_PARTIAL_OBJECT       0x101B
#define MTP_OP_GET_PARTIAL_OBJECT_64    0x95C1  // Android vendor extension
#define MTP_OP_GET_OBJECT_PROPS_SUPPORTED 0x9801
#define MTP_OP_GET_OBJECT_PROP_VALUE    0x9802
#define MTP_OP_SET_OBJECT_PROP_VALUE    0x9803
#define MTP_OP_SEND_OBJECT_PROP_LIST    0x9808  // MTP modern object creation

// MTP DataType codes for ObjectPropList (Object Property List)
#define MTP_DATATYPE_UINT8              0x0002
#define MTP_DATATYPE_UINT16             0x0004
#define MTP_DATATYPE_UINT32             0x0006
#define MTP_DATATYPE_UINT64             0x000A
#define MTP_DATATYPE_STRING             0xFFFF

// Object format codes (MTP spec §6.2)
#define MTP_FORMAT_UNDEFINED            0x3000
#define MTP_FORMAT_ASSOCIATION          0x3001  // Folder
#define MTP_FORMAT_JPEG                 0x3801
#define MTP_FORMAT_PNG                  0x380B
#define MTP_FORMAT_TIFF                 0x380D
#define MTP_FORMAT_BMP                  0x3804
#define MTP_FORMAT_GIF                  0x3807
#define MTP_FORMAT_MP4                  0xB982
#define MTP_FORMAT_3GP                  0xB984
#define MTP_FORMAT_AVI                  0x300A
#define MTP_FORMAT_WMV                  0xB981
#define MTP_FORMAT_MP3                  0x3009
#define MTP_FORMAT_WAV                  0x3008
#define MTP_FORMAT_WMA                  0xB901
#define MTP_FORMAT_AAC                  0xB903
#define MTP_FORMAT_FLAC                 0xB906
#define MTP_FORMAT_DNG                  0x3811

// Object property codes
#define MTP_PROP_STORAGE_ID             0xDC01
#define MTP_PROP_OBJECT_FORMAT          0xDC02
#define MTP_PROP_OBJECT_SIZE            0xDC04
#define MTP_PROP_OBJECT_FILENAME        0xDC07
#define MTP_PROP_DATE_CREATED           0xDC08
#define MTP_PROP_DATE_MODIFIED          0xDC09
#define MTP_PROP_PARENT_OBJECT          0xDC0B
#define MTP_PROP_NAME                   0xDC44

// ============================================================================
// MTP Container Structure (12-byte header, little-endian)
// ============================================================================

#pragma pack(push, 1)

typedef struct {
    uint32_t length;          // Total container length (header + payload)
    uint16_t type;            // MTP_CONTAINER_COMMAND/DATA/RESPONSE/EVENT
    uint16_t code;            // Operation or response code
    uint32_t transaction_id;  // Monotonically increasing per session
} mtp_container_t;

#pragma pack(pop)

#define MTP_CONTAINER_HEADER_SIZE 12
#define MTP_MAX_PARAMS 5

// ============================================================================
// MTP Object Info (parsed from GetObjectInfo response)
// ============================================================================

typedef struct {
    uint32_t object_handle;
    uint32_t storage_id;
    uint16_t object_format;
    uint32_t compressed_size;   // File size (32-bit, use object_size_64 for large files)
    uint64_t object_size_64;    // 64-bit size from ObjectPropValue if available
    uint32_t parent_object;
    uint16_t association_type;  // 0x0001 = folder
    char filename[256];
    char date_created[20];      // "YYYYMMDDTHHmmss" format
    char date_modified[20];
} mtp_object_info_t;

// ============================================================================
// MTP Storage Info
// ============================================================================

typedef struct {
    uint32_t storage_id;
    uint16_t storage_type;      // 0x0003 = fixed RAM, 0x0004 = removable RAM
    uint16_t filesystem_type;   // 0x0002 = generic hierarchical
    uint16_t access_capability; // 0x0000 = read-write
    uint64_t max_capacity;
    uint64_t free_space;
    char description[128];
    char volume_label[128];
} mtp_storage_info_t;

// ============================================================================
// USB I/O Callback Interface
//
// The Swift layer provides these callbacks to perform actual USB pipe I/O.
// This decouples the MTP protocol logic from the USB transport.
// ============================================================================

typedef struct {
    // Send data to device (bulk-out endpoint)
    // Returns bytes sent, or -1 on error
    ssize_t (*bulk_write)(const void *data, size_t length, void *context);

    // Receive data from device (bulk-in endpoint)
    // Returns bytes received, or -1 on error
    ssize_t (*bulk_read)(void *buffer, size_t max_length, void *context);

    // Send/receive on interrupt endpoint (for events)
    // Returns bytes transferred, or -1 on error
    ssize_t (*interrupt_read)(void *buffer, size_t max_length, void *context);

    // Opaque context passed to all callbacks (holds IOUSBHostPipe references)
    void *context;
} mtp_usb_interface_t;

// ============================================================================
// MTP Session State
// ============================================================================

// Supported-operations cap. MTP spec (§5) reserves 0x1000–0xFFFF so there
// are ~61k opcodes, but real devices advertise <256. libmtp uses a dynamic
// malloc'd array; we use a fixed buffer to keep the session POD-allocatable.
#define MTP_MAX_SUPPORTED_OPS 512

typedef struct {
    uint32_t session_id;
    uint32_t transaction_id;    // Auto-incremented per operation
    int is_open;                // 1 if session is active
    uint32_t storage_ids[16];   // Discovered storage IDs
    int storage_count;

    // Pre-allocated I/O buffers (avoids per-operation malloc)
    void *cmd_buf;              // Command buffer (64 bytes)
    void *data_buf;             // Data phase buffer (configurable, typically 4 MB)
    size_t data_buf_size;

    // USB interface callbacks
    mtp_usb_interface_t usb;

    // Supported operations advertised by the device (parsed from GetDeviceInfo).
    // Populated by mtp_parse_device_info() or mtp_get_device_info_parsed().
    // Consumers must check has_device_info before trusting supported_ops.
    int has_device_info;
    uint16_t supported_ops[MTP_MAX_SUPPORTED_OPS];
    int supported_ops_count;

    // Vendor extension ID from DeviceInfo (0x00000006 = Microsoft MTP, etc.).
    // Useful for distinguishing standard MTP from PTP-only cameras.
    uint32_t vendor_extension_id;

    // If set, the device emits a 64-bit ObjectCompressedSize in ObjectInfo
    // datasets (Samsung Galaxy quirk). Detected at parse time by
    // mtp_parse_object_info, used when packing outgoing ObjectInfo.
    // Matches libmtp's PTPParams::ocs64 flag.
    int ocs64;

    // Error state
    uint16_t last_response_code;
    char last_error[256];
} mtp_session_t;

// ============================================================================
// Session Lifecycle
// ============================================================================

/// Create a new MTP session with pre-allocated buffers.
/// @param data_buf_size Size of the data transfer buffer (0 = default 4 MB)
/// @param usb USB interface callbacks (bulk_read, bulk_write, interrupt_read)
/// @return Session handle, or NULL on allocation failure
mtp_session_t *mtp_session_create(size_t data_buf_size, mtp_usb_interface_t usb);

/// Destroy a session and free all buffers.
void mtp_session_destroy(mtp_session_t *session);

/// Open an MTP session on the device.
/// @return 0 on success, -1 on error (check session->last_error)
int mtp_open_session(mtp_session_t *session);

/// Close the MTP session.
int mtp_close_session(mtp_session_t *session);

// ============================================================================
// Device & Storage Operations
// ============================================================================

/// Get device info (model, serial, supported operations).
/// Populates session->last_error on failure.
/// @param info_buf Output buffer for raw device info data
/// @param info_buf_size Size of output buffer
/// @param bytes_out Actual bytes written
/// @return 0 on success, -1 on error
int mtp_get_device_info(mtp_session_t *session, void *info_buf,
                        size_t info_buf_size, size_t *bytes_out);

/// Fetch GetDeviceInfo and parse the SupportedOperations array into the
/// session. Must be called once after mtp_open_session() if you plan to
/// gate optional operations (e.g., SendObjectPropList 0x9808) on device
/// capability. On success, session->has_device_info is set and
/// mtp_operation_supported() returns meaningful results.
/// @return 0 on success, -1 on error (check session->last_error)
int mtp_get_device_info_parsed(mtp_session_t *session);

/// Check whether the device advertises a given MTP operation code in its
/// GetDeviceInfo response. Requires mtp_get_device_info_parsed() to have
/// been called first; returns 0 if device info was never fetched (fail-closed:
/// callers must treat "unknown" as "not supported" and use fallback paths).
/// @return 1 if supported, 0 otherwise
int mtp_operation_supported(const mtp_session_t *session, uint16_t opcode);

/// Discover storage IDs. Populates session->storage_ids and storage_count.
int mtp_get_storage_ids(mtp_session_t *session);

/// Get storage info for a specific storage ID.
int mtp_get_storage_info(mtp_session_t *session, uint32_t storage_id,
                         mtp_storage_info_t *info);

// ============================================================================
// Object Enumeration
// ============================================================================

/// Get object handles in a directory.
/// @param storage_id Storage to enumerate
/// @param parent_handle Parent folder handle (0xFFFFFFFF for root)
/// @param format_filter Object format filter (0x00000000 for all)
/// @param handles Output array (caller-allocated)
/// @param max_handles Maximum handles to return
/// @return Number of handles found, or -1 on error
int mtp_get_object_handles(mtp_session_t *session, uint32_t storage_id,
                           uint32_t parent_handle, uint32_t format_filter,
                           uint32_t *handles, int max_handles);

/// Get object info for a single handle.
int mtp_get_object_info(mtp_session_t *session, uint32_t handle,
                        mtp_object_info_t *info);

/// Batch get object info for multiple handles (reduces USB round-trips).
/// Calls GetObjectInfo for each handle sequentially but in a tight C loop
/// without returning to Swift between calls.
/// @param handles Array of object handles
/// @param infos Output array of object info structs
/// @param count Number of handles
/// @return Number of successfully retrieved infos
int mtp_get_object_info_batch(mtp_session_t *session, const uint32_t *handles,
                              mtp_object_info_t *infos, int count);

// ============================================================================
// File Transfer (Hot Path)
// ============================================================================

/// Pull a file from device directly to a file descriptor.
/// Uses the session's pre-allocated data buffer — zero per-file allocation.
/// Writes with F_NOCACHE to avoid buffer cache pollution.
/// @param session MTP session
/// @param handle Object handle to retrieve
/// @param dst_fd Destination file descriptor (opened with O_WRONLY)
/// @param file_size Expected file size (from GetObjectInfo)
/// @param bytes_written Output: actual bytes written
/// @param progress_fn Optional progress callback (called per chunk)
/// @param progress_ctx Context for progress callback
/// @return 0 on success, -1 on error
int mtp_get_object_to_fd(mtp_session_t *session, uint32_t handle,
                         int dst_fd, uint64_t file_size,
                         uint64_t *bytes_written,
                         void (*progress_fn)(uint64_t bytes_so_far, void *ctx),
                         void *progress_ctx);

/// Pull a partial object (for chunked/resumed transfers).
/// @param offset Byte offset to start reading from
/// @param length Number of bytes to read
int mtp_get_partial_object_to_fd(mtp_session_t *session, uint32_t handle,
                                 uint64_t offset, uint64_t length,
                                 int dst_fd, uint64_t *bytes_written);

/// Pull a partial object using Android's 64-bit extension (opcode 0x95C1).
/// Supports offsets and lengths > 4 GB for large video files (4K/8K).
/// Returns -1 with "Operation Not Supported" if device lacks this extension.
int mtp_get_partial_object_64_to_fd(mtp_session_t *session, uint32_t handle,
                                    uint64_t offset, uint64_t length,
                                    int dst_fd, uint64_t *bytes_written);

/// Push a file from a file descriptor to the device.
/// @param parent_handle Destination folder handle
/// @param storage_id Target storage
/// @param filename Filename on device
/// @param file_size Size of the file to send
/// @param src_fd Source file descriptor (opened with O_RDONLY)
/// @param new_handle Output: handle assigned by device
/// @param progress_fn Optional callback invoked per chunk during the
///   Phase 2 (SendObject) streaming loop. Receives bytes-sent-so-far.
///   NULL to disable. Invoked on the calling thread from inside the
///   bulk transfer loop — keep the callback fast and non-blocking.
/// @param progress_ctx Opaque context pointer passed to progress_fn.
/// @return 0 on success, -1 on error
int mtp_send_object_from_fd(mtp_session_t *session, uint32_t parent_handle,
                            uint32_t storage_id, const char *filename,
                            uint64_t file_size, uint16_t format,
                            int src_fd, uint32_t *new_handle,
                            void (*progress_fn)(uint64_t bytes_so_far, void *ctx),
                            void *progress_ctx);

/// Push a file using SendObjectPropList (modern MTP, used by libmtp/OpenMTP).
/// Uses MTP_OP_SEND_OBJECT_PROP_LIST (0x9808) which is more reliable than
/// the legacy SendObjectInfo on Android 10+ devices. Supports 64-bit file sizes
/// natively without the 4GB limit workaround.
/// @param parent_handle Destination folder handle
/// @param storage_id Target storage
/// @param filename Filename on device
/// @param file_size Size of the file to send (64-bit, no 4GB limit)
/// @param format Object format code (e.g., MTP_FORMAT_UNDEFINED for arbitrary)
/// @param src_fd Source file descriptor (opened with O_RDONLY)
/// @param new_handle Output: handle assigned by device
/// @param progress_fn Optional per-chunk progress callback (see
///   mtp_send_object_from_fd for semantics).
/// @param progress_ctx Opaque context pointer passed to progress_fn.
/// @return 0 on success, -1 on error
int mtp_send_object_proplist_from_fd(mtp_session_t *session, uint32_t parent_handle,
                                     uint32_t storage_id, const char *filename,
                                     uint64_t file_size, uint16_t format,
                                     int src_fd, uint32_t *new_handle,
                                     void (*progress_fn)(uint64_t bytes_so_far, void *ctx),
                                     void *progress_ctx);

// ============================================================================
// Object Management
// ============================================================================

/// Delete an object on the device.
int mtp_delete_object(mtp_session_t *session, uint32_t handle);

/// Rename an object (set filename property).
int mtp_rename_object(mtp_session_t *session, uint32_t handle,
                      const char *new_name);

/// Create a folder on the device.
/// @param parent_handle Parent folder (0xFFFFFFFF for root)
/// @param storage_id Target storage
/// @param folder_name Name of the new folder
/// @param new_handle Output: handle of created folder
/// @return 0 on success, -1 on error
int mtp_create_folder(mtp_session_t *session, uint32_t parent_handle,
                      uint32_t storage_id, const char *folder_name,
                      uint32_t *new_handle);

// ============================================================================
// Low-Level Container Building & Parsing
// ============================================================================

/// Build a command container with parameters.
/// @param buf Output buffer (must be at least 12 + 4*param_count bytes)
/// @param code Operation code
/// @param txn_id Transaction ID
/// @param params Parameter array (up to 5)
/// @param param_count Number of parameters
/// @return Total container size in bytes
int mtp_build_command(void *buf, uint16_t code, uint32_t txn_id,
                      const uint32_t *params, int param_count);

/// Parse a response container.
/// @param buf Input buffer containing the response
/// @param len Length of data in buffer
/// @param out Parsed container header
/// @param params Output parameter array (up to 5)
/// @param param_count Output: number of parameters in response
/// @return 0 on success, -1 if buffer too small or invalid
int mtp_parse_response(const void *buf, size_t len, mtp_container_t *out,
                       uint32_t *params, int *param_count);

/// Parse a data container header (first 12 bytes of data phase).
/// @param buf Input buffer
/// @param len Length of data
/// @param out Parsed header
/// @param payload_offset Output: offset to payload data after header
/// @return 0 on success, -1 on error
int mtp_parse_data_header(const void *buf, size_t len, mtp_container_t *out,
                          size_t *payload_offset);

// ============================================================================
// MTP String Parsing (UTF-16LE → UTF-8)
// ============================================================================

/// Parse an MTP string (length-prefixed UTF-16LE) to UTF-8.
/// @param src Source buffer pointing to the MTP string
/// @param src_len Available bytes in source
/// @param dst Destination UTF-8 buffer
/// @param dst_size Size of destination buffer
/// @return Number of bytes consumed from src, or -1 on error
int mtp_parse_string(const uint8_t *src, size_t src_len,
                     char *dst, size_t dst_size);

/// Build an MTP string (UTF-8 → length-prefixed UTF-16LE).
/// @param utf8 Input UTF-8 string
/// @param dst Output buffer for MTP string
/// @param dst_size Size of output buffer
/// @return Number of bytes written to dst, or -1 on error
int mtp_build_string(const char *utf8, uint8_t *dst, size_t dst_size);

// ============================================================================
// Utility
// ============================================================================

/// Get human-readable string for an MTP response code.
const char *mtp_response_string(uint16_t code);

/// Get human-readable string for an MTP operation code.
const char *mtp_operation_string(uint16_t code);

#endif // MTP_CORE_H
