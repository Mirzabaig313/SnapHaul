// CMTPCore — USB Transport Layer (libusb-1.0)
// Copyright (c) 2026 SnapHaul Contributors — GPL-3.0
//
// Provides USB I/O for the MTP protocol stack using libusb-1.0.
// Handles device open, interface claiming, endpoint discovery, and
// bulk/interrupt transfers. Decouples MTP protocol logic from USB hardware.

#ifndef MTP_USB_TRANSPORT_H
#define MTP_USB_TRANSPORT_H

#include "mtp_core.h"
#include <stdint.h>

/// Open a USB transport connection to an MTP device.
///
/// Initializes libusb, finds the device by vendor/product ID, detaches any
/// kernel driver (e.g., macOS PTPCamera), claims the MTP interface, and
/// discovers bulk-in, bulk-out, and interrupt endpoints.
///
/// On failure, `out_context` may still be set (for error retrieval). The caller
/// MUST call `mtp_usb_transport_close()` on `out_context` regardless of the
/// return value if `out_context` is non-NULL after the call.
///
/// @param vendor_id USB vendor ID of the target device
/// @param product_id USB product ID of the target device
/// @param out_interface Output: populated mtp_usb_interface_t with callbacks
/// @param out_context Output: opaque transport context (pass to close/error)
/// @return 0 on success, -1 on error (call mtp_usb_transport_error for details)
int mtp_usb_transport_open(uint16_t vendor_id, uint16_t product_id,
                           mtp_usb_interface_t *out_interface,
                           void **out_context);

/// Close the USB transport and release all resources.
///
/// Releases the USB interface, closes the device handle, and shuts down
/// the libusb context. Safe to call with NULL context (no-op).
///
/// @param context Opaque transport context from mtp_usb_transport_open
void mtp_usb_transport_close(void *context);

/// Get the last error message from the transport layer.
///
/// @param context Opaque transport context
/// @return Human-readable error string, or "no transport" if context is NULL
const char *mtp_usb_transport_error(void *context);

/// Reset the USB device (useful for recovery after stall/timeout).
///
/// @param context Opaque transport context
/// @return 0 on success, -1 on error
int mtp_usb_transport_reset(void *context);

#endif // MTP_USB_TRANSPORT_H
