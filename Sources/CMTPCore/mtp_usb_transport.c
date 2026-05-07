// CMTPCore — USB Transport Layer (libusb-1.0)
// Copyright (c) 2026 SnapHaul Contributors — GPL-3.0
//
// Implements USB I/O for MTP using libusb-1.0. This replaces the placeholder
// file-descriptor-based callbacks with real USB bulk/interrupt transfers.

#include "mtp_usb_transport.h"
#include <libusb.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

// MTP interface class/subclass/protocol per USB Still Image spec
#define MTP_INTERFACE_CLASS      6
#define MTP_INTERFACE_SUBCLASS   1
#define MTP_INTERFACE_PROTOCOL   1

// USB transfer timeout in milliseconds (MTP spec recommends 10s for bulk)
#define USB_TIMEOUT_MS           10000

// Interrupt endpoint timeout (short — events are non-critical)
#define USB_INTERRUPT_TIMEOUT_MS 1000

// Internal transport state — opaque to Swift
typedef struct {
    libusb_context *usb_ctx;
    libusb_device_handle *handle;
    int interface_number;
    uint8_t ep_bulk_in;
    uint8_t ep_bulk_out;
    uint8_t ep_interrupt;
    char last_error[256];
} mtp_transport_t;

// ============================================================================
// USB Callback Implementations
// ============================================================================

/// Bulk write callback — sends MTP command/data containers to device.
static ssize_t transport_bulk_write(const void *data, size_t length, void *ctx) {
    mtp_transport_t *t = (mtp_transport_t *)ctx;
    if (!t || !t->handle || !data) return -1;

    int transferred = 0;
    int r = libusb_bulk_transfer(
        t->handle,
        t->ep_bulk_out,
        (unsigned char *)data,
        (int)length,
        &transferred,
        USB_TIMEOUT_MS
    );

    if (r != 0) {
        snprintf(t->last_error, sizeof(t->last_error),
                 "USB bulk write failed (%d bytes): %s",
                 (int)length, libusb_strerror(r));
        return -1;
    }

    return (ssize_t)transferred;
}

/// Bulk read callback — receives MTP response/data containers from device.
static ssize_t transport_bulk_read(void *buffer, size_t max_length, void *ctx) {
    mtp_transport_t *t = (mtp_transport_t *)ctx;
    if (!t || !t->handle || !buffer) return -1;

    int transferred = 0;
    int r = libusb_bulk_transfer(
        t->handle,
        t->ep_bulk_in,
        (unsigned char *)buffer,
        (int)max_length,
        &transferred,
        USB_TIMEOUT_MS
    );

    if (r == LIBUSB_ERROR_TIMEOUT && transferred == 0) {
        // Full timeout with no data — report as error so CMTPCore doesn't spin
        snprintf(t->last_error, sizeof(t->last_error),
                 "USB bulk read timed out (%d ms, 0 bytes received)", USB_TIMEOUT_MS);
        return -1;
    }

    if (r != 0 && r != LIBUSB_ERROR_TIMEOUT) {
        snprintf(t->last_error, sizeof(t->last_error),
                 "USB bulk read failed (max %d bytes): %s",
                 (int)max_length, libusb_strerror(r));
        return -1;
    }

    // LIBUSB_ERROR_TIMEOUT with transferred > 0 is a short read — valid for MTP
    return (ssize_t)transferred;
}

/// Interrupt read callback — receives MTP event notifications from device.
static ssize_t transport_interrupt_read(void *buffer, size_t max_length, void *ctx) {
    mtp_transport_t *t = (mtp_transport_t *)ctx;
    if (!t || !t->handle || !buffer) return -1;
    if (t->ep_interrupt == 0) return -1;  // No interrupt endpoint found

    int transferred = 0;
    int r = libusb_interrupt_transfer(
        t->handle,
        t->ep_interrupt,
        (unsigned char *)buffer,
        (int)max_length,
        &transferred,
        USB_INTERRUPT_TIMEOUT_MS
    );

    // Timeout on interrupt is normal (no pending events) — return 0
    if (r == LIBUSB_ERROR_TIMEOUT) return 0;

    if (r != 0) {
        snprintf(t->last_error, sizeof(t->last_error),
                 "USB interrupt read failed: %s", libusb_strerror(r));
        return -1;
    }

    return (ssize_t)transferred;
}

// ============================================================================
// Endpoint Discovery
// ============================================================================

/// Find MTP interface and endpoints on the device.
/// Searches for USB Still Image class (6/1/1) first, then falls back to
/// vendor-specific (0xFF) with MTP-like endpoint topology (2 bulk + 1 interrupt).
/// Two-pass approach ensures we don't accidentally claim ADB or serial interfaces.
static int find_mtp_endpoints(mtp_transport_t *t) {
    libusb_device *dev = libusb_get_device(t->handle);
    struct libusb_config_descriptor *config = NULL;

    int r = libusb_get_active_config_descriptor(dev, &config);
    if (r != 0) {
        snprintf(t->last_error, sizeof(t->last_error),
                 "Failed to get config descriptor: %s", libusb_strerror(r));
        return -1;
    }

    int found = 0;

    // Pass 1: Look for standard MTP interface (class 6/1/1 — USB Still Image)
    for (int i = 0; i < config->bNumInterfaces && !found; i++) {
        const struct libusb_interface *iface = &config->interface[i];

        for (int j = 0; j < iface->num_altsetting && !found; j++) {
            const struct libusb_interface_descriptor *alt = &iface->altsetting[j];

            if (alt->bInterfaceClass != MTP_INTERFACE_CLASS ||
                alt->bInterfaceSubClass != MTP_INTERFACE_SUBCLASS ||
                alt->bInterfaceProtocol != MTP_INTERFACE_PROTOCOL) {
                continue;
            }

            t->interface_number = alt->bInterfaceNumber;
            t->ep_bulk_in = 0;
            t->ep_bulk_out = 0;
            t->ep_interrupt = 0;

            for (int k = 0; k < alt->bNumEndpoints; k++) {
                const struct libusb_endpoint_descriptor *ep = &alt->endpoint[k];
                uint8_t type = ep->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK;
                uint8_t dir = ep->bEndpointAddress & LIBUSB_ENDPOINT_DIR_MASK;

                if (type == LIBUSB_TRANSFER_TYPE_BULK) {
                    if (dir == LIBUSB_ENDPOINT_IN) {
                        t->ep_bulk_in = ep->bEndpointAddress;
                    } else {
                        t->ep_bulk_out = ep->bEndpointAddress;
                    }
                } else if (type == LIBUSB_TRANSFER_TYPE_INTERRUPT &&
                           dir == LIBUSB_ENDPOINT_IN) {
                    t->ep_interrupt = ep->bEndpointAddress;
                }
            }

            if (t->ep_bulk_in && t->ep_bulk_out) {
                found = 1;
            }
        }
    }

    // Pass 2: Fallback to vendor-specific (0xFF) with MTP-like topology.
    // Some Android devices (Xiaomi, OnePlus) expose MTP under vendor class.
    // Require exactly 3 endpoints (2 bulk + 1 interrupt) to avoid matching
    // ADB (2 bulk, no interrupt) or serial debug interfaces.
    for (int i = 0; i < config->bNumInterfaces && !found; i++) {
        const struct libusb_interface *iface = &config->interface[i];

        for (int j = 0; j < iface->num_altsetting && !found; j++) {
            const struct libusb_interface_descriptor *alt = &iface->altsetting[j];

            if (alt->bInterfaceClass != 0xFF) continue;
            if (alt->bNumEndpoints != 3) continue;  // MTP = 2 bulk + 1 interrupt

            t->interface_number = alt->bInterfaceNumber;
            t->ep_bulk_in = 0;
            t->ep_bulk_out = 0;
            t->ep_interrupt = 0;

            int bulk_count = 0;
            int interrupt_count = 0;

            for (int k = 0; k < alt->bNumEndpoints; k++) {
                const struct libusb_endpoint_descriptor *ep = &alt->endpoint[k];
                uint8_t type = ep->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK;
                uint8_t dir = ep->bEndpointAddress & LIBUSB_ENDPOINT_DIR_MASK;

                if (type == LIBUSB_TRANSFER_TYPE_BULK) {
                    bulk_count++;
                    if (dir == LIBUSB_ENDPOINT_IN) {
                        t->ep_bulk_in = ep->bEndpointAddress;
                    } else {
                        t->ep_bulk_out = ep->bEndpointAddress;
                    }
                } else if (type == LIBUSB_TRANSFER_TYPE_INTERRUPT &&
                           dir == LIBUSB_ENDPOINT_IN) {
                    interrupt_count++;
                    t->ep_interrupt = ep->bEndpointAddress;
                }
            }

            // Must have exactly 2 bulk (1 in + 1 out) and 1 interrupt-in
            if (t->ep_bulk_in && t->ep_bulk_out &&
                bulk_count == 2 && interrupt_count == 1) {
                found = 1;
            }
        }
    }

    libusb_free_config_descriptor(config);

    if (!found) {
        snprintf(t->last_error, sizeof(t->last_error),
                 "No MTP interface found (need bulk-in + bulk-out endpoints)");
        return -1;
    }

    return 0;
}

// ============================================================================
// Public API
// ============================================================================

int mtp_usb_transport_open(uint16_t vendor_id, uint16_t product_id,
                           mtp_usb_interface_t *out_interface,
                           void **out_context) {
    if (!out_interface || !out_context) return -1;

    *out_context = NULL;

    mtp_transport_t *t = calloc(1, sizeof(mtp_transport_t));
    if (!t) return -1;

    *out_context = t;

    fprintf(stderr, "[USB] Step 1: libusb_init...\n");
    int r = libusb_init(&t->usb_ctx);
    if (r != 0) {
        snprintf(t->last_error, sizeof(t->last_error),
                 "libusb_init failed: %s", libusb_strerror(r));
        fprintf(stderr, "[USB] FAILED: %s\n", t->last_error);
        return -1;
    }
    fprintf(stderr, "[USB] Step 1: OK\n");

    fprintf(stderr, "[USB] Step 2: open_device_with_vid_pid(VID=%04x, PID=%04x)...\n", vendor_id, product_id);
    for (int attempt = 0; attempt < 3; attempt++) {
        t->handle = libusb_open_device_with_vid_pid(t->usb_ctx, vendor_id, product_id);
        if (t->handle) break;
        if (attempt < 2) {
            fprintf(stderr, "[USB] Step 2: attempt %d failed, retrying...\n", attempt + 1);
            usleep(attempt == 0 ? 200000 : 500000);
        }
    }

    if (!t->handle) {
        libusb_device **devs = NULL;
        ssize_t dev_count = libusb_get_device_list(t->usb_ctx, &devs);
        fprintf(stderr, "[USB] Step 2: FAILED — device not found. %zd USB devices visible.\n", dev_count);

        if (dev_count > 0 && devs) {
            for (ssize_t i = 0; i < dev_count; i++) {
                struct libusb_device_descriptor desc;
                if (libusb_get_device_descriptor(devs[i], &desc) != 0) continue;
                fprintf(stderr, "[USB]   Device %zd: VID=%04x PID=%04x class=%d\n",
                        i, desc.idVendor, desc.idProduct, desc.bDeviceClass);

                if (desc.idVendor == vendor_id && desc.idProduct == product_id) {
                    fprintf(stderr, "[USB]   ^ MATCH — trying libusb_open directly...\n");
                    r = libusb_open(devs[i], &t->handle);
                    if (r == 0 && t->handle) {
                        fprintf(stderr, "[USB]   ^ Direct open succeeded!\n");
                        libusb_free_device_list(devs, 1);
                        goto device_opened;
                    }
                    fprintf(stderr, "[USB]   ^ Direct open FAILED: %s\n", libusb_strerror(r));
                    snprintf(t->last_error, sizeof(t->last_error),
                             "Device found (VID=%04x PID=%04x) but open failed: %s",
                             vendor_id, product_id, libusb_strerror(r));
                    libusb_free_device_list(devs, 1);
                    return -1;
                }
            }
            libusb_free_device_list(devs, 1);
        }

        snprintf(t->last_error, sizeof(t->last_error),
                 "Device not found (VID=%04x PID=%04x) — %zd USB devices visible",
                 vendor_id, product_id, dev_count > 0 ? dev_count : 0);
        return -1;
    }
    fprintf(stderr, "[USB] Step 2: OK — device handle acquired\n");

device_opened:

    fprintf(stderr, "[USB] Step 3: set_auto_detach_kernel_driver...\n");
    libusb_set_auto_detach_kernel_driver(t->handle, 1);
    fprintf(stderr, "[USB] Step 3: OK\n");

    fprintf(stderr, "[USB] Step 4: find_mtp_endpoints...\n");
    if (find_mtp_endpoints(t) != 0) {
        fprintf(stderr, "[USB] Step 4: FAILED — %s\n", t->last_error);
        return -1;
    }
    fprintf(stderr, "[USB] Step 4: OK — interface=%d, bulk_in=0x%02x, bulk_out=0x%02x, interrupt=0x%02x\n",
            t->interface_number, t->ep_bulk_in, t->ep_bulk_out, t->ep_interrupt);

    fprintf(stderr, "[USB] Step 5: checking kernel driver on interface %d...\n", t->interface_number);
    int kd = libusb_kernel_driver_active(t->handle, t->interface_number);
    fprintf(stderr, "[USB] Step 5: kernel_driver_active = %d (%s)\n", kd,
            kd == 1 ? "YES — driver attached" : kd == 0 ? "no driver" : "error/not supported");

    if (kd == 1) {
        fprintf(stderr, "[USB] Step 5b: detaching kernel driver...\n");
        int dr = libusb_detach_kernel_driver(t->handle, t->interface_number);
        fprintf(stderr, "[USB] Step 5b: detach result = %d (%s)\n", dr, libusb_strerror(dr));
        if (dr == 0) {
            usleep(200000);
        }
    }

    fprintf(stderr, "[USB] Step 6: claim_interface(%d)...\n", t->interface_number);
    r = libusb_claim_interface(t->handle, t->interface_number);
    fprintf(stderr, "[USB] Step 6: result = %d (%s)\n", r, libusb_strerror(r));

    if (r != 0) {
        snprintf(t->last_error, sizeof(t->last_error),
                 "Failed to claim USB interface %d: %s (is another app using the device?)",
                 t->interface_number, libusb_strerror(r));
        fprintf(stderr, "[USB] FAILED: %s\n", t->last_error);
        return -1;
    }

    fprintf(stderr, "[USB] Step 7: SUCCESS — interface claimed, populating callbacks\n");

    out_interface->bulk_write = transport_bulk_write;
    out_interface->bulk_read = transport_bulk_read;
    out_interface->interrupt_read = transport_interrupt_read;
    out_interface->context = t;

    return 0;
}

void mtp_usb_transport_close(void *context) {
    if (!context) return;
    mtp_transport_t *t = (mtp_transport_t *)context;

    if (t->handle) {
        libusb_release_interface(t->handle, t->interface_number);
        libusb_close(t->handle);
    }

    if (t->usb_ctx) {
        libusb_exit(t->usb_ctx);
    }

    free(t);
}

const char *mtp_usb_transport_error(void *context) {
    if (!context) return "no transport";
    return ((mtp_transport_t *)context)->last_error;
}

int mtp_usb_transport_reset(void *context) {
    if (!context) return -1;
    mtp_transport_t *t = (mtp_transport_t *)context;

    if (!t->handle) {
        snprintf(t->last_error, sizeof(t->last_error), "No device handle for reset");
        return -1;
    }

    int r = libusb_reset_device(t->handle);
    if (r != 0) {
        snprintf(t->last_error, sizeof(t->last_error),
                 "USB device reset failed: %s", libusb_strerror(r));
        return -1;
    }

    // Re-claim interface after reset
    r = libusb_claim_interface(t->handle, t->interface_number);
    if (r != 0) {
        snprintf(t->last_error, sizeof(t->last_error),
                 "Failed to re-claim interface after reset: %s", libusb_strerror(r));
        return -1;
    }

    return 0;
}
