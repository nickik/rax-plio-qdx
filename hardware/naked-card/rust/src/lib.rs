#![forbid(unsafe_code)]

use qli_model::{DeviceToQic, MmioRequest, MmioResponse, QicToDevice};

pub const PLIO_ID: u32 = 0x504c_494f; // Test fixture value: ASCII "PLIO".
pub const TEST_VENDOR_ID: u16 = 0xffff;
pub const TEST_DEVICE_ID: u16 = 0x0001;
pub const TEST_REVISION: u16 = 0x0001;

pub const CFG_ID: u32 = 0x00;
pub const CFG_VENDOR_DEVICE: u32 = 0x04;
pub const CFG_REV_CLASS_FLAGS: u32 = 0x08;
pub const CFG_QDX: u32 = 0x0c;
pub const CFG_MMIO_LENGTH: u32 = 0x10;
pub const CFG_DEVICE_STATUS: u32 = 0x14;
pub const CFG_DEVICE_CONTROL: u32 = 0x18;

/// Minimal QLI endpoint: worker-only configuration space and nothing else.
#[derive(Debug, Default, Clone, Copy)]
pub struct NakedDevice {
    pending_response: Option<MmioResponse>,
}

impl NakedDevice {
    pub const fn new() -> Self { Self { pending_response: None } }

    pub fn drive(&self) -> DeviceToQic {
        DeviceToQic {
            mmio_ready: self.pending_response.is_none(),
            mmio_response: self.pending_response,
            dma_completion_ready: true,
            ..DeviceToQic::default()
        }
    }

    pub fn clock(&mut self, qic: &QicToDevice) {
        if qic.reset || qic.mmio_cancel {
            self.pending_response = None;
            return;
        }

        if self.pending_response.is_some() && qic.mmio_response_ready {
            self.pending_response = None;
        }

        if self.pending_response.is_none() {
            if let Some(request) = qic.mmio_request {
                self.pending_response = Some(self.handle_mmio(request));
            }
        }
    }

    pub fn handle_mmio(&self, req: MmioRequest) -> MmioResponse { naked_mmio(req) }
}

/// Pure semantic response used by both the cycle model and conformance vectors.
pub fn naked_mmio(req: MmioRequest) -> MmioResponse {
    if req.validate().is_err() { return MmioResponse::Error; }

    let aligned = req.address & !3;
    if req.write {
        return if aligned == CFG_DEVICE_CONTROL {
            MmioResponse::WriteOk
        } else {
            MmioResponse::Error
        };
    }

    let data = match aligned {
        CFG_ID => PLIO_ID,
        CFG_VENDOR_DEVICE => u32::from(TEST_VENDOR_ID) | (u32::from(TEST_DEVICE_ID) << 16),
        CFG_REV_CLASS_FLAGS => {
            let device_class = 0u32;
            let worker_only_flags = 1u32;
            u32::from(TEST_REVISION) | (device_class << 16) | (worker_only_flags << 24)
        }
        // PLIO's reserved profile word is zero for this deliberately non-QDX fixture.
        CFG_QDX => 0,
        CFG_MMIO_LENGTH => 0x100,
        CFG_DEVICE_STATUS => 0,
        CFG_DEVICE_CONTROL => 0,
        _ => return MmioResponse::Error,
    };
    MmioResponse::ReadOk(data)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(address: u32, byte_enable: u8) -> MmioRequest {
        MmioRequest { address, write: false, byte_enable, write_data: 0 }
    }

    #[test]
    fn naked_device_is_worker_only() {
        assert_eq!(naked_mmio(read(CFG_REV_CLASS_FLAGS, 0xf)), MmioResponse::ReadOk(u32::from(TEST_REVISION) | (1 << 24)));
    }

    #[test]
    fn config_words_support_valid_8_16_32_bit_accesses() {
        let combined = u32::from(TEST_VENDOR_ID) | (u32::from(TEST_DEVICE_ID) << 16);
        assert_eq!(naked_mmio(read(CFG_VENDOR_DEVICE, 0xf)), MmioResponse::ReadOk(combined));
        assert_eq!(naked_mmio(read(CFG_VENDOR_DEVICE, 0x3)), MmioResponse::ReadOk(combined));
        assert_eq!(naked_mmio(read(CFG_VENDOR_DEVICE + 2, 0xc)), MmioResponse::ReadOk(combined));
        assert_eq!(naked_mmio(read(CFG_VENDOR_DEVICE + 3, 0x8)), MmioResponse::ReadOk(combined));
    }

    #[test]
    fn invalid_or_unknown_worker_access_errors() {
        assert_eq!(naked_mmio(read(CFG_VENDOR_DEVICE + 1, 0x3)), MmioResponse::Error);
        assert_eq!(naked_mmio(read(0x80, 0xf)), MmioResponse::Error);
    }

    #[test]
    fn mmio_cancel_discards_a_pending_response() {
        let mut dev = NakedDevice::new();
        let req = read(CFG_ID, 0xf);
        dev.clock(&QicToDevice { mmio_request: Some(req), ..QicToDevice::default() });
        assert!(dev.drive().mmio_response.is_some());
        dev.clock(&QicToDevice { mmio_cancel: true, ..QicToDevice::default() });
        assert!(dev.drive().mmio_response.is_none());
        assert!(dev.drive().mmio_ready);
    }
}
