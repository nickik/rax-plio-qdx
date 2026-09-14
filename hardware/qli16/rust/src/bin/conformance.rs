use plio_logical_model::BurstWords;
use qli16_model::*;
use qli_model::{DmaCompletion, DmaDirection, DmaRequest, DmaStatus, DmaWord, MmioRequest, MmioResponse, NotificationRequest};

fn dump(name: &str, tokens: &[Token]) {
    print!("VECTOR {name}");
    for t in tokens {
        let dir = match t.direction { Direction::QicToDevice => 0, Direction::DeviceToQic => 1 };
        print!(" {:01x}:{:01x}:{:04x}", dir, t.kind as u8, t.payload);
    }
    println!();
}

fn main() {
    dump("MMIO_READ8", &encode_mmio_request(MmioRequest { address: 0x101, write: false, byte_enable: 0x2, write_data: 0 }).unwrap());
    dump("MMIO_WRITE32", &encode_mmio_request(MmioRequest { address: 0x104, write: true, byte_enable: 0xf, write_data: 0x89ab_cdef }).unwrap());
    dump("MMIO_READ_OK", &encode_mmio_response(MmioResponse::ReadOk(0x1234_5678)));
    dump("MMIO_WRITE_OK", &encode_mmio_response(MmioResponse::WriteOk));
    dump("MMIO_ERROR", &encode_mmio_response(MmioResponse::Error));

    for (name, words) in [("DMA1", BurstWords::One), ("DMA4", BurstWords::Four), ("DMA8", BurstWords::Eight), ("DMA16", BurstWords::Sixteen)] {
        dump(name, &encode_dma_request(DmaRequest { direction: DmaDirection::DeviceToHost, address: 0x1234_5000, words }).unwrap());
    }
    dump("DMA_DATA", &encode_dma_word(DmaWord { data: 0xaabb_ccdd }, Direction::DeviceToQic));

    for (name, status) in [
        ("COMP_OK", DmaStatus::Ok),
        ("COMP_BUS", DmaStatus::BusError),
        ("COMP_PAR", DmaStatus::ParityError),
        ("COMP_TIMEOUT", DmaStatus::Timeout),
        ("COMP_PROTO", DmaStatus::ProtocolError),
    ] {
        dump(name, &[encode_dma_completion(DmaCompletion { status, words_completed: if status == DmaStatus::Ok { 4 } else { 3 } }).unwrap()]);
    }

    for channel in 0..4 {
        dump(&format!("NOTIFY{channel}"), &[encode_notification(NotificationRequest { channel }).unwrap()]);
    }
}
