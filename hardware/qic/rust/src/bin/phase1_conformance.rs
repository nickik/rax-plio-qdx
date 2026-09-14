use plio_logical_model::{odd_parity_32, BusToCard, BurstWords, CardToBus, Space};
use plio_qic_model::Qic;
use qli_model::{DeviceToQic, DmaStatus, MmioResponse, QicToDevice};

fn worker(address: u32, read: bool, be: u8) -> BusToCard {
    BusToCard {
        selected: true,
        ad: Some(address),
        par: Some(odd_parity_32(address)),
        space: Some(Space::Worker),
        address_strobe: true,
        read,
        byte_enable: be,
        burst: BurstWords::One,
        ..BusToCard::default()
    }
}

fn stimulus(cycle: u32) -> (BusToCard, &'static str) {
    match cycle {
        0 | 5 | 7 | 9 => (BusToCard { reset: true, ..BusToCard::default() }, "reset"),
        1 => (BusToCard::default(), "idle"),
        2 => {
            let mut b = worker(0x100, true, 0xf);
            b.selected = false;
            (b, "idle")
        }
        3 => {
            let mut b = worker(0x100, true, 0xf);
            b.space = Some(Space::HostDma);
            (b, "idle")
        }
        4 => (worker(0x101, true, 0x2), "worker_address"),
        6 => (worker(0x102, false, 0xc), "worker_address"),
        8 => (worker(0x104, true, 0xf), "worker_address"),
        10 => (worker(0x0200_0000, true, 0x1), "fault"),
        11 => (worker(0x101, true, 0x3), "fault"),
        12 => {
            let mut b = worker(0x100, true, 0xf);
            b.burst = BurstWords::Four;
            (b, "fault")
        }
        13 => {
            let mut b = worker(0x100, true, 0xf);
            b.par = None;
            (b, "fault")
        }
        14 => {
            let mut b = worker(0x100, true, 0xf);
            b.par = Some(odd_parity_32(0x100) ^ 1);
            (b, "fault")
        }
        15 => {
            let mut b = worker(0x100, true, 0xf);
            b.ad = None;
            (b, "fault")
        }
        _ => unreachable!(),
    }
}

fn bool_digit(v: bool) -> u8 { u8::from(v) }
fn space_code(v: Option<Space>) -> u8 { v.map(|x| x as u8).unwrap_or(0) }
fn burst_code(v: BurstWords) -> u8 { v.blen() }

fn mmio_kind(resp: Option<MmioResponse>) -> u8 {
    match resp {
        None => 0,
        Some(MmioResponse::ReadOk(_)) => 0,
        Some(MmioResponse::WriteOk) => 1,
        Some(MmioResponse::Error) => 2,
    }
}

fn dma_status_code(v: DmaStatus) -> u8 {
    match v {
        DmaStatus::Ok => 0,
        DmaStatus::BusError => 1,
        DmaStatus::ParityError => 2,
        DmaStatus::Timeout => 3,
        DmaStatus::ProtocolError => 4,
    }
}

fn format_trace(
    cycle: u32,
    bus: &BusToCard,
    dev: &DeviceToQic,
    card: &CardToBus,
    qic: &QicToDevice,
    event: &str,
) -> String {
    let pi_ad = bus.ad.unwrap_or(0);
    let pi_par = bus.par.unwrap_or(0) & 0xf;
    let po_ad = card.ad.unwrap_or(0);
    let po_par = card.par.unwrap_or(0) & 0xf;

    let (mmio_resp_data, mmio_resp_kind) = match dev.mmio_response {
        Some(MmioResponse::ReadOk(data)) => (data, mmio_kind(dev.mmio_response)),
        Some(other) => (0, mmio_kind(Some(other))),
        None => (0, 0),
    };
    let (dma_req_v, dma_dir, dma_addr, dma_words) = match dev.dma_request {
        Some(r) => (1, r.direction as u8, r.address, r.words.blen()),
        None => (0, 0, 0, 0),
    };
    let dma_write_data = dev.dma_write.map(|w| w.data).unwrap_or(0);
    let (notif_v, notif_ch) = dev.notification_request.map(|n| (1, n.channel)).unwrap_or((0, 0));

    let (mmio_addr, mmio_write, mmio_be, mmio_wdata) = qic
        .mmio_request
        .map(|r| (r.address, bool_digit(r.write), r.byte_enable, r.write_data))
        .unwrap_or((0, 0, 0, 0));
    let dma_read_data = qic.dma_read.map(|w| w.data).unwrap_or(0);
    let (dma_comp_status, dma_comp_words) = qic
        .dma_completion
        .map(|c| (dma_status_code(c.status), c.words_completed))
        .unwrap_or((0, 0));

    format!(
        "TRACE|v1|c={cycle:08x}|pi={}.{}.{}.{}.{pi_ad:08x}.{}.{pi_par:x}.{}.{:x}.{}.{}.{:x}.{:x}.{}.{}.{:x}|qi={}.{}.{}.{mmio_resp_data:08x}.{}.{:x}.{dma_addr:08x}.{:x}.{}.{}.{dma_write_data:08x}.{}.{}.{:x}|po={}.{}.{po_ad:08x}.{}.{po_par:x}.{}.{:x}.{}.{}.{:x}.{:x}.{}.{}.{:x}|qo={}.{}.{mmio_addr:08x}.{}.{mmio_be:x}.{mmio_wdata:08x}.{}.{}.{}.{}.{dma_read_data:08x}.{}.{}.{dma_comp_status:02x}.{:x}.{}|ev={event}",
        bool_digit(bus.reset), bool_digit(bus.selected), bool_digit(bus.grant), bool_digit(bus.ad.is_some()),
        bool_digit(bus.par.is_some()), bool_digit(bus.space.is_some()), space_code(bus.space),
        bool_digit(bus.address_strobe), bool_digit(bus.read), bus.byte_enable, burst_code(bus.burst), bool_digit(bus.data_strobe), bool_digit(bus.ack), bool_digit(bus.err),
        bool_digit(dev.mmio_ready), bool_digit(dev.mmio_response.is_some()), mmio_resp_kind,
        dma_req_v, dma_dir, dma_words, bool_digit(dev.dma_read_ready), bool_digit(dev.dma_write.is_some()), bool_digit(dev.dma_completion_ready), notif_v, notif_ch,
        bool_digit(card.request), bool_digit(card.ad.is_some()), bool_digit(card.par.is_some()), bool_digit(card.space.is_some()), space_code(card.space), bool_digit(card.address_strobe), bool_digit(card.read), card.byte_enable, burst_code(card.burst), bool_digit(card.data_strobe), bool_digit(card.ack), bool_digit(card.err),
        bool_digit(qic.reset), bool_digit(qic.mmio_request.is_some()), mmio_write, bool_digit(qic.mmio_response_ready), bool_digit(qic.mmio_cancel), bool_digit(qic.dma_request_ready), bool_digit(qic.dma_read.is_some()), bool_digit(qic.dma_write_ready), bool_digit(qic.dma_completion.is_some()), dma_comp_words, bool_digit(qic.notification_ready),
    )
}

fn main() {
    let mut qic = Qic::new();
    let dev = DeviceToQic::default();

    for cycle in 0..16u32 {
        let (bus, event) = stimulus(cycle);
        let (card, local) = qic.drive(&bus, &dev);

        assert!(local.mmio_request.is_none(), "Phase 1 emitted QLI MMIO on cycle {cycle}");
        assert!(!card.request && card.ad.is_none() && card.par.is_none() && card.space.is_none());
        assert!(!card.address_strobe && !card.data_strobe);
        assert!(!(card.ack && card.err));

        let expected_ack = matches!(cycle, 4 | 6 | 8);
        let expected_err = matches!(cycle, 10 | 11 | 12 | 13 | 14 | 15);
        assert_eq!(card.ack, expected_ack, "ACK mismatch cycle {cycle}");
        assert_eq!(card.err, expected_err, "ERR mismatch cycle {cycle}");
        assert_eq!(local.reset, bus.reset, "reset mismatch cycle {cycle}");

        println!("{}", format_trace(cycle, &bus, &dev, &card, &local, event));
        qic.clock(&bus, &dev);
    }
}
