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

    qic.clock(&waiting_bus, &DeviceToQic::default());
    let (_, after_timeout) = qic.drive(&waiting_bus, &DeviceToQic::default());
    let completion = after_timeout.dma_completion.expect("timeout completion");
    assert_eq!(completion.status, DmaStatus::Timeout);
    assert_eq!(completion.words_completed, 0);
}

#[test]
fn device_to_host_local_stall_cannot_pin_grant_forever() {
    let mut qic = Qic::new();
    let request = DmaRequest {
        direction: DmaDirection::DeviceToHost,
        address: 0x1300_0000,
        words: BurstWords::Four,
    };

    qic.clock(
        &BusToCard::default(),
        &DeviceToQic { dma_request: Some(request), ..DeviceToQic::default() },
    );
    qic.clock(&BusToCard { grant: true, ..BusToCard::default() }, &DeviceToQic::default());
    qic.clock(&BusToCard { grant: true, ..BusToCard::default() }, &DeviceToQic::default());

    let granted = BusToCard { grant: true, ..BusToCard::default() };
    for _ in 0..PLIO_TIMEOUT_CYCLES {
        qic.clock(&granted, &DeviceToQic::default());
    }

    let (card, local) = qic.drive(&granted, &DeviceToQic::default());
    assert!(!card.request);
    let completion = local.dma_completion.expect("local stall completion");
    assert_eq!(completion.status, DmaStatus::Timeout);
    assert_eq!(completion.words_completed, 0);
}

#[test]
fn worker_timeout_is_one_total_data_phase_budget() {
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

    // Spend most of the timeout waiting for the endpoint to accept the request.
    for _ in 0..200 {
        qic.clock(&waiting_host, &DeviceToQic::default());
    }

    // QLI accepts the request, but does not produce a response. Acceptance must
    // not restart the PLIO timeout counter.
    qic.clock(
        &waiting_host,
        &DeviceToQic { mmio_ready: true, ..DeviceToQic::default() },
    );

    for _ in 0..55 {
        qic.clock(&waiting_host, &DeviceToQic::default());
    }

    let (card, _) = qic.drive(&waiting_host, &DeviceToQic::default());
    assert!(card.err);
    assert!(!card.ack);
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

#[test]
fn losing_grant_mid_dma_reports_protocol_error() {
    let mut qic = Qic::new();
    let request = DmaRequest {
        direction: DmaDirection::HostToDevice,
        address: 0x1400_0000,
        words: BurstWords::Four,
    };

    qic.clock(
        &BusToCard::default(),
        &DeviceToQic { dma_request: Some(request), ..DeviceToQic::default() },
    );
    qic.clock(&BusToCard { grant: true, ..BusToCard::default() }, &DeviceToQic::default());
    qic.clock(&BusToCard { grant: true, ..BusToCard::default() }, &DeviceToQic::default());
    qic.clock(&BusToCard::default(), &DeviceToQic::default());

    let (_, local) = qic.drive(&BusToCard::default(), &DeviceToQic::default());
    let completion = local.dma_completion.expect("grant-loss completion");
    assert_eq!(completion.status, DmaStatus::ProtocolError);
    assert_eq!(completion.words_completed, 0);
}

#[test]
fn dma_address_phase_times_out_without_ack_or_err() {
    let mut qic = Qic::new();
    let request = DmaRequest {
        direction: DmaDirection::HostToDevice,
        address: 0x1500_0000,
        words: BurstWords::Four,
    };
    qic.clock(
        &BusToCard::default(),
        &DeviceToQic { dma_request: Some(request), ..DeviceToQic::default() },
    );
    qic.clock(&BusToCard { grant: true, ..BusToCard::default() }, &DeviceToQic::default());

    let granted_no_response = BusToCard { grant: true, ..BusToCard::default() };
    for _ in 0..PLIO_TIMEOUT_CYCLES {
        qic.clock(&granted_no_response, &DeviceToQic::default());
    }

    let (_, local) = qic.drive(&granted_no_response, &DeviceToQic::default());
    let completion = local.dma_completion.expect("address timeout completion");
    assert_eq!(completion.status, DmaStatus::Timeout);
    assert_eq!(completion.words_completed, 0);
}

#[test]
fn accepted_worker_mmio_is_cancelled_if_plio_data_phase_times_out() {
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

    let data_phase = BusToCard {
        selected: true,
        data_strobe: true,
        read: true,
        byte_enable: 0xf,
        ..BusToCard::default()
    };
    // Accept the local request immediately, then never produce its response.
    qic.clock(
        &data_phase,
        &DeviceToQic { mmio_ready: true, ..DeviceToQic::default() },
    );
    for _ in 0..(PLIO_TIMEOUT_CYCLES - 1) {
        qic.clock(&data_phase, &DeviceToQic::default());
    }

    let (card, local) = qic.drive(&data_phase, &DeviceToQic::default());
    assert!(card.err);
    assert!(local.mmio_cancel);
}
