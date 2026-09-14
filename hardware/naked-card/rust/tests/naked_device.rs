use naked_card::*;
use qli_model::{MmioRequest, MmioResponse};

fn read(address: u32, byte_enable: u8) -> MmioRequest {
    MmioRequest { address, write: false, byte_enable, write_data: 0 }
}

#[test]
fn naked_device_identifies_as_worker_only() {
    let dev = NakedDevice::new();
    assert_eq!(dev.handle_mmio(read(CFG_ID, 0xf)), MmioResponse::ReadOk(PLIO_ID));

    let response = dev.handle_mmio(read(CFG_REV_CLASS_FLAGS, 0xf));
    let MmioResponse::ReadOk(word) = response else { panic!("expected config read") };
    assert_eq!((word >> 24) & 0xff, 1);
}

#[test]
fn naked_device_has_no_arbitrary_mmio_surface() {
    let dev = NakedDevice::new();
    assert_eq!(dev.handle_mmio(read(0x1000, 0xf)), MmioResponse::Error);
}

#[test]
fn naked_device_accepts_only_test_control_write() {
    let dev = NakedDevice::new();
    let req = MmioRequest { address: CFG_DEVICE_CONTROL, write: true, byte_enable: 0xf, write_data: 0x1234_5678 };
    assert_eq!(dev.handle_mmio(req), MmioResponse::WriteOk);
}

#[test]
fn naked_device_rejects_misaligned_or_noncontiguous_byte_enables() {
    let dev = NakedDevice::new();
    assert_eq!(dev.handle_mmio(read(CFG_VENDOR_DEVICE + 1, 0x3)), MmioResponse::Error);
    assert_eq!(dev.handle_mmio(read(CFG_VENDOR_DEVICE, 0x5)), MmioResponse::Error);
}
