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
        if qic.reset {
            self.pending_response = None;
            return;
        }

        let consumed = self.pending_response.is_some() && qic.mmio_response_ready;
        if consumed { self.pending_response = None; }

        if self.pending_response.is_none() {
            if let Some(request) = qic.mmio_request {
                let response = self.handle_mmio(request);
                self.pending_response = Some(response);
            }
        }
    }

    pub fn handle_mmio(&self, req: MmioRequest) -> MmioResponse {
        if req.validate().is_err() { return MmioResponse::Error(1); }

        if req.write {
            return if req.address == CFG_DEVICE_CONTROL { MmioResponse::WriteOk } else { MmioResponse::Error(2) };
        }

        let data = match req.address {
            CFG_ID => PLIO_ID,
            CFG_VENDOR_DEVICE => u32::from(TEST_VENDOR_ID) | (u32::from(TEST_DEVICE_ID) << 16),
            CFG_REV_CLASS_FLAGS => {
                let device_class = 0u32;
                let worker_only_flags = 1u32;
                u32::from(TEST_REVISION) | (device_class << 16) | (worker_only_flags << 24)
            }
            CFG_QDX => 0,
            CFG_MMIO_LENGTH => 0x100,
            CFG_DEVICE_STATUS => 0,
            CFG_DEVICE_CONTROL => 0,
            _ => return MmioResponse::Error(3),
        };
        MmioResponse::ReadOk(data)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn naked_device_is_worker_only_and_not_qdx() {
        let dev = NakedDevice::new();
        let flags = dev.handle_mmio(MmioRequest { address: CFG_REV_CLASS_FLAGS, write: false, byte_enable: 0xf, write_data: 0 });
        assert_eq!(flags, MmioResponse::ReadOk(u32::from(TEST_REVISION) | (1 << 24)));
        assert_eq!(dev.handle_mmio(MmioRequest { address: CFG_QDX, write: false, byte_enable: 0xf, write_data: 0 }), MmioResponse::ReadOk(0));
    }

    #[test]
    fn unknown_register_errors() {
        let dev = NakedDevice::new();
        assert!(matches!(dev.handle_mmio(MmioRequest { address: 0x80, write: false, byte_enable: 0xf, write_data: 0 }), MmioResponse::Error(_)));
    }
}
