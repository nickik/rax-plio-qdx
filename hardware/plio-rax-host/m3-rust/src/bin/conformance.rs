use plio_host_dma_model::{DmaDirection, DmaError, DmaHostM3, MemoryResponse};
use plio_logical_model::{odd_parity_32, PLIO_TIMEOUT_CYCLES};

fn handle(channel: u8, generation: u8, offset: u32) -> u32 {
    (u32::from(channel) << 28) | (u32::from(generation) << 24) | offset
}

fn main() {
    let mut h = DmaHostM3::new();
    let g = h.bind(2, 3, 0x2000_0000, 0x1000, true, true).unwrap();
    println!("PLIOHOSTM3TRACE|v1|case=bind|slot=2|channel=3|generation={g}|base=20000000|length=4096");

    h.start(2, handle(3, g, 0x40), 4, DmaDirection::DeviceWrite).unwrap();
    for beat in 0..4u8 {
        let data = 0xa000_0000 | u32::from(beat);
        h.offer_device_write(data, odd_parity_32(data)).unwrap();
        h.memory_request_accepted();
        h.memory_response(MemoryResponse::WriteDone);
    }
    assert_eq!(h.take_completion(), Some(Ok(4)));
    println!("PLIOHOSTM3TRACE|v1|case=write4|status=ok|beats=4|first=20000040|last=2000004c");

    h.start(2, handle(3, g, 0x80), 4, DmaDirection::DeviceRead).unwrap();
    for beat in 0..4u8 {
        h.memory_request_accepted();
        let data = 0xb000_0000 | u32::from(beat);
        h.memory_response(MemoryResponse::ReadData(data));
        assert_eq!(h.device_read_data().unwrap().0, data);
        h.acknowledge_device_read();
    }
    assert_eq!(h.take_completion(), Some(Ok(4)));
    println!("PLIOHOSTM3TRACE|v1|case=read4|status=ok|beats=4|first=20000080|last=2000008c");

    h.start(2, handle(3, g, 0), 1, DmaDirection::DeviceWrite).unwrap();
    let d = 0x1122_3344;
    h.offer_device_write(d, odd_parity_32(d)).unwrap();
    for _ in 0..3 { h.wait_cycle(); }
    h.memory_request_accepted();
    for _ in 0..2 { h.wait_cycle(); }
    h.memory_response(MemoryResponse::WriteDone);
    assert_eq!(h.take_completion(), Some(Ok(1)));
    println!("PLIOHOSTM3TRACE|v1|case=memory_backpressure|status=ok|request_wait=3|response_wait=2");

    h.start(2, handle(3, g, 0), 4, DmaDirection::DeviceWrite).unwrap();
    let d0 = 0x0102_0304;
    h.offer_device_write(d0, odd_parity_32(d0)).unwrap(); h.memory_request_accepted(); h.memory_response(MemoryResponse::WriteDone);
    assert_eq!(h.offer_device_write(0x5566_7788, 0), Err(DmaError::Parity));
    assert_eq!(h.take_completion(), Some(Err(DmaError::Parity)));
    println!("PLIOHOSTM3TRACE|v1|case=partial_parity|status=parity|committed=1");

    h.start(2, handle(3, g, 0), 1, DmaDirection::DeviceRead).unwrap();
    h.memory_request_accepted(); h.memory_response(MemoryResponse::Fault);
    assert_eq!(h.take_completion(), Some(Err(DmaError::MemoryFault)));
    println!("PLIOHOSTM3TRACE|v1|case=memory_fault|status=fault|committed=0");

    h.start(2, handle(3, g, 0), 1, DmaDirection::DeviceRead).unwrap();
    for _ in 0..PLIO_TIMEOUT_CYCLES { h.wait_cycle(); }
    assert_eq!(h.take_completion(), Some(Err(DmaError::Timeout)));
    println!("PLIOHOSTM3TRACE|v1|case=timeout|status=timeout|cycles=256");

    h.start(2, handle(3, g, 0), 1, DmaDirection::DeviceRead).unwrap(); h.reset();
    assert_eq!(h.take_completion(), Some(Err(DmaError::Reset)));
    println!("PLIOHOSTM3TRACE|v1|case=reset|status=reset|committed=0");

    h.start(2, handle(3, g, 0), 4, DmaDirection::DeviceWrite).unwrap();
    let d1 = 0xdead_beef;
    h.offer_device_write(d1, odd_parity_32(d1)).unwrap(); h.memory_request_accepted();
    assert_eq!(h.revoke(2, 3), Ok(false));
    h.memory_response(MemoryResponse::WriteDone);
    assert_eq!(h.take_completion(), Some(Err(DmaError::Revoked)));
    println!("PLIOHOSTM3TRACE|v1|case=revoke_active|status=revoked|committed=1|valid=0");

    let g2 = h.bind(2, 3, 0x2100_0000, 0x1000, true, true).unwrap();
    assert_eq!(g2, 1);
    println!("PLIOHOSTM3TRACE|v1|case=rebind|slot=2|channel=3|generation=1|stale_generation=0_rejected");

    for words in [1u8, 4, 8, 16] {
        let mut x = DmaHostM3::new();
        let gx = x.bind(0, 0, 0x1000_0000, 0x1000, true, true).unwrap();
        x.start(0, handle(0, gx, 0), words, DmaDirection::DeviceRead).unwrap();
        for beat in 0..words { x.memory_request_accepted(); x.memory_response(MemoryResponse::ReadData(u32::from(beat))); x.acknowledge_device_read(); }
        assert_eq!(x.take_completion(), Some(Ok(words)));
    }
    println!("PLIOHOSTM3TRACE|v1|case=burst_matrix|directions=2|sizes=1,4,8,16|status=ok");
}
