use naked_card::{naked_mmio, CFG_DEVICE_CONTROL, CFG_ID, CFG_MMIO_LENGTH, CFG_REV_CLASS_FLAGS, CFG_VENDOR_DEVICE};
use qli_model::{MmioRequest, MmioResponse};

fn emit(kind: &str, req: MmioRequest) {
    let response = naked_mmio(req);
    match response {
        MmioResponse::ReadOk(data) => println!("VECTOR {kind} {:08x} R {:08x}", req.address, data),
        MmioResponse::WriteOk => println!("VECTOR {kind} {:08x} W 00000000", req.address),
        MmioResponse::Error => println!("VECTOR {kind} {:08x} E 00000000", req.address),
    }
}

fn read(address: u32, byte_enable: u8) -> MmioRequest {
    MmioRequest { address, write: false, byte_enable, write_data: 0 }
}

fn main() {
    emit("READ32", read(CFG_ID, 0xf));
    emit("READ32", read(CFG_VENDOR_DEVICE, 0xf));
    emit("READ16", read(CFG_VENDOR_DEVICE, 0x3));
    emit("READ16", read(CFG_VENDOR_DEVICE + 2, 0xc));
    emit("READ8", read(CFG_REV_CLASS_FLAGS + 3, 0x8));
    emit("READ32", read(CFG_MMIO_LENGTH, 0xf));
    emit("BADALIGN", read(CFG_VENDOR_DEVICE + 1, 0x3));
    emit("UNKNOWN", read(0x80, 0xf));
    emit(
        "WRITE32",
        MmioRequest { address: CFG_DEVICE_CONTROL, write: true, byte_enable: 0xf, write_data: 0x1234_5678 },
    );
}
