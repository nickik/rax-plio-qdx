use plio_logical_model::BurstWords;
use qli16_model::codec::{CycleResult, LinkCodec, SlotTrace};
use qli_model::{
    DeviceToQic, DmaCompletion, DmaDirection, DmaRequest, DmaStatus, DmaWord, MmioRequest,
    MmioResponse, NotificationRequest, QicToDevice,
};

const CYCLES: u32 = 4096;

fn lfsr_step(mut x: u16) -> u16 {
    x ^= x << 7;
    x ^= x >> 9;
    x ^= x << 8;
    x
}

fn slot_word(s: &SlotTrace, high: bool) -> u32 {
    let dir = match s.token.direction {
        qli16_model::Direction::QicToDevice => 0u32,
        qli16_model::Direction::DeviceToQic => 1u32,
    };
    let mut v = u32::from(s.token.payload);
    v ^= (s.token.kind as u32) << 17;
    v ^= dir << 21;
    v ^= (s.valid as u32) << 22;
    v ^= (s.ack as u32) << 23;
    if high { v.rotate_left(11) } else { v }
}

fn mix(mut checksum: u32, cycle: u32, r: &CycleResult) -> u32 {
    let mut word = slot_word(&r.slots[0], false) ^ slot_word(&r.slots[1], true);
    word ^= (r.to_qic.mmio_ready as u32) << 1;
    word ^= (r.to_qic.mmio_response.is_some() as u32) << 2;
    word ^= (r.to_qic.dma_request.is_some() as u32) << 3;
    word ^= (r.to_qic.dma_read_ready as u32) << 4;
    word ^= (r.to_qic.dma_write.is_some() as u32) << 5;
    word ^= (r.to_qic.dma_completion_ready as u32) << 6;
    word ^= (r.to_qic.notification_request.is_some() as u32) << 7;
    word ^= (r.to_device.mmio_request.is_some() as u32) << 8;
    word ^= (r.to_device.mmio_response_ready as u32) << 9;
    word ^= (r.to_device.dma_request_ready as u32) << 10;
    word ^= (r.to_device.dma_read.is_some() as u32) << 11;
    word ^= (r.to_device.dma_write_ready as u32) << 12;
    word ^= (r.to_device.dma_completion.is_some() as u32) << 13;
    word ^= (r.to_device.notification_ready as u32) << 14;
    word ^= (r.protocol_fault as u32) << 15;
    checksum = checksum.rotate_left(5) ^ word ^ cycle;
    checksum
}

fn main() {
    let mut link = LinkCodec::new();
    let mut lfsr: u16 = 0xace1;
    let mut checksum: u32 = 0x514c_4931;
    let mut qsrc: u8 = 0;
    let mut dsrc: u8 = 0;
    let mut resets = 0u32;

    for cycle in 0..CYCLES {
        if cycle % 257 == 0 {
            qsrc = 0;
            dsrc = 0;
            let r = link.cycle(true, QicToDevice::default(), DeviceToQic::default());
            checksum = mix(checksum, cycle, &r);
            resets += 1;
            lfsr = lfsr_step(lfsr);
            continue;
        }

        if qsrc == 0 {
            qsrc = match lfsr & 0x3 {
                0 => 1,
                1 => 2,
                2 => 3,
                _ => 0,
            };
        }
        if dsrc == 0 {
            dsrc = match (lfsr >> 2) & 0x7 {
                0 => 1,
                1 => 2,
                2 => 3,
                3 => 4,
                _ => 0,
            };
        }

        let mut q = QicToDevice::default();
        match qsrc {
            1 => q.mmio_request = Some(MmioRequest {
                address: 0x100,
                write: false,
                byte_enable: 0xf,
                write_data: 0,
            }),
            2 => q.dma_read = Some(DmaWord { data: 0x1122_3344 }),
            3 => q.dma_completion = Some(DmaCompletion {
                status: DmaStatus::BusError,
                words_completed: 2,
            }),
            _ => {}
        }
        q.mmio_response_ready = lfsr & (1 << 8) != 0;
        q.dma_request_ready = lfsr & (1 << 9) != 0;
        q.dma_write_ready = lfsr & (1 << 10) != 0;
        q.notification_ready = lfsr & (1 << 11) != 0;

        let mut d = DeviceToQic::default();
        d.mmio_ready = lfsr & (1 << 4) != 0;
        d.dma_read_ready = lfsr & (1 << 5) != 0;
        d.dma_completion_ready = lfsr & (1 << 6) != 0;
        match dsrc {
            1 => d.mmio_response = Some(MmioResponse::ReadOk(0x3344_5566)),
            2 => d.dma_request = Some(DmaRequest {
                direction: DmaDirection::DeviceToHost,
                address: 0x1234_5000,
                words: BurstWords::Four,
            }),
            3 => d.dma_write = Some(DmaWord { data: 0x5566_7788 }),
            4 => d.notification_request = Some(NotificationRequest { channel: 2 }),
            _ => {}
        }

        let r = link.cycle(false, q, d);
        assert!(!r.protocol_fault, "legal stress stimulus produced protocol fault at cycle {cycle}");

        match qsrc {
            1 if r.to_qic.mmio_ready => qsrc = 0,
            2 if r.to_qic.dma_read_ready => qsrc = 0,
            3 if r.to_qic.dma_completion_ready => qsrc = 0,
            _ => {}
        }
        match dsrc {
            1 if r.to_device.mmio_response_ready => dsrc = 0,
            2 if r.to_device.dma_request_ready => dsrc = 0,
            3 if r.to_device.dma_write_ready => dsrc = 0,
            4 if r.to_device.notification_ready => dsrc = 0,
            _ => {}
        }

        checksum = mix(checksum, cycle, &r);
        lfsr = lfsr_step(lfsr);
    }

    println!(
        "STRESSTRACE|v1|cycles={CYCLES}|resets={resets}|checksum={checksum:08x}|lfsr={lfsr:04x}"
    );
}
