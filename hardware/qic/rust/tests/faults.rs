use plio_logical_model::{odd_parity_32, BusToCard, BurstWords, Space, PLIO_TIMEOUT_CYCLES};
use plio_qic_model::Qic;
use qli_model::{DeviceToQic, DmaDirection, DmaRequest, DmaStatus};

#[test]
fn dma_times_out_after_256_unacknowledged_bus_clocks() {
    let mut qic = Qic::new();
    let request = DmaRequest {
        direction: DmaDirection::HostToDevice,
        address: 0x1200_0000,
        words: BurstWords::Four,
    };

    qic.clock(
        &BusToCard::default(),
        &DeviceToQic { dma_request: Some(request), ..DeviceToQic::default() },
    );
    qic.clock(&BusToCard { grant: true, ..BusToCard::default() }, &DeviceToQic::default());
    qic.clock(&BusToCard { grant: true, ..BusToCard::default() }, &DeviceToQic::default());

    let waiting_bus = BusToCard { grant: true, ..BusToCard::default() };
    for _ in 0..(PLIO_TIMEOUT_CYCLES - 1) {
        let (_, local) = qic.drive(&waiting_bus, &DeviceToQic::default());
        assert!(local.dma_completion.is_none());
        qic.clock(&waiting_bus, &DeviceToQic::default());
    }

    let (_, before_timeout) = qic.drive(&waiting_bus, &DeviceToQic::default());
    assert!(before_timeout.dma_completion.is_none());
    qic.clock(&waiting_bus, &DeviceToQic::default());

    let (_, after_timeout) = qic.drive(&waiting_bus, &DeviceToQic::default());
    let completion = after_timeout.dma_completion.expect("timeout completion");
    assert_eq!(completion.status, DmaStatus::Timeout);
    assert_eq!(completion.words_completed, 0);
}

#[test]
fn worker_wait_timeout_returns_plio_error_without_fabricating_a_response() {
    let mut qic = Qic::new();
    let address = 0x40;
    let address_cycle = BusToCard {
        selected: true,
        ad: Some(address),
        par: Some(odd_parity_32(address)),
        space: Some(Space::Worker),
        address_strobe: true,
        read: true,
        byte_enable: 0xf,
        burst: BurstWords::One,
        ..BusToCard::default()
    };
    qic.clock(&address_cycle, &DeviceToQic::default());

    let waiting_host = BusToCard { selected: true, data_strobe: true, read: true, byte_enable: 0xf, ..BusToCard::default() };
    for _ in 0..(PLIO_TIMEOUT_CYCLES - 1) {
        let (card, local) = qic.drive(&waiting_host, &DeviceToQic::default());
        assert!(!card.ack);
        assert!(!card.err);
        assert!(local.mmio_request.is_some());
        qic.clock(&waiting_host, &DeviceToQic::default());
    }

    let (card, _) = qic.drive(&waiting_host, &DeviceToQic::default());
    assert!(card.err);
    assert!(!card.ack);
    qic.clock(&waiting_host, &DeviceToQic::default());
    assert!(qic.is_idle());
}

#[test]
fn reset_forces_all_bus_drives_inactive() {
    let qic = Qic::new();
    let reset = BusToCard { reset: true, grant: true, selected: true, ..BusToCard::default() };
    let (card, local) = qic.drive(&reset, &DeviceToQic::default());
    assert!(local.reset);
    assert!(!card.request);
    assert!(!card.address_strobe);
    assert!(!card.data_strobe);
    assert!(card.ad.is_none());
    assert!(card.par.is_none());
    assert!(!card.ack);
    assert!(!card.err);
}
