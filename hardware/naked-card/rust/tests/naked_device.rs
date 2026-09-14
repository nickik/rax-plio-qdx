use naked_card::*;
use qli_model::{MmioRequest, MmioResponse};

fn read32(address: u32) -> MmioRequest {
    MmioRequest { address, write: false, byte_enable: 0xf, write_data: 0 }
}

#[test]
fn naked_device_identifies_as_worker_only() {
    let mut dev = NakedDevice::new();
    assert_eq!(dev.handle_mmio(read32(CFG_ID)), MmioResponse::ReadOk(PLIO_ID));

    let response = dev.handle_mmio(read32(CFG_REV_CLASS_FLAGS));
    let MmioResponse::ReadOk(word) = response else { panic!("expected config read") };
    assert_eq!((word >> 24) & 0xff, 1); // worker only
}

#[test]
fn naked_device_has_no_arbitrary_mmio_surface() {
    let mut dev = NakedDevice::new();
    assert!(matches!(dev.handle_mmio(read32(0x1000)), MmioResponse::Error(_)));
}

#[test]
fn naked_device_accepts_only_test_control_write() {
    let mut dev = NakedDevice::new();
    let req = MmioRequest { address: CFG_DEVICE_CONTROL, write: true, byte_enable: 0xf, write_data: 0x1234_5678 };
    assert_eq!(dev.handle_mmio(req), MmioResponse::WriteOk);
}
