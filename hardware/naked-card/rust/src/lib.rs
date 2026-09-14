#![forbid(unsafe_code)]

use qli_model::{MmioRequest, MmioResponse};

pub const PLIO_ID: u32 = 0x504c_494f; // Test fixture value: ASCII "PLIO".
pub const TEST_VENDOR_ID: u16 = 0xffff;
pub const TEST_DEVICE_ID: u16 = 0x0001;
pub const TEST_REVISION: u16 = 0x0001;

pub const CFG_ID: u32 = 0x00;
pub const CFG_VENDOR_DEVICE: u32 = 0x04;
pub const CFG_REV_CLASS_FLAGS: u32 = 0x08;
pub const CFG_MMIO_LENGTH: u32 = 0x10;
pub const CFG_DEVICE_STATUS: u32 = 0x14;
pub const CFG_DEVICE_CONTROL: u32 = 0x18;

/// Minimal QLI endpoint used to validate the QIC without any real device logic.
#[derive(Debug, Default, Clone, Copy)]
pub struct NakedDevice;

impl NakedDevice {
    pub const fn new() -> Self { Self }

    pub fn handle_mmio(&mut self, req: MmioRequest) -> MmioResponse {
        if req.validate().is_err() {
            return MmioResponse::Error(1);
        }

        if req.write {
            return if req.address == CFG_DEVICE_CONTROL {
                MmioResponse::WriteOk
            } else {
                MmioResponse::Error(2)
            };
        }

        let data = match req.address {
            CFG_ID => PLIO_ID,
            CFG_VENDOR_DEVICE => u32::from(TEST_VENDOR_ID) | (u32::from(TEST_DEVICE_ID) << 16),
            CFG_REV_CLASS_FLAGS => {
                let device_class = 0u32;
                let worker_only_flags = 1u32; // PLIO FLAGS bit 0: worker.
                u32::from(TEST_REVISION) | (device_class << 16) | (worker_only_flags << 24)
            }
            CFG_MMIO_LENGTH => 0x100,
            CFG_DEVICE_STATUS => 0,
            CFG_DEVICE_CONTROL => 0,
            _ => return MmioResponse::Error(3),
        };
        MmioResponse::ReadOk(data)
    }
}
