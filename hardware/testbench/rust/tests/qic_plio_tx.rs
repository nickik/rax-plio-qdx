use plio_logical_model::{odd_parity_32, BusToCard, BurstWords, CardToBus, Space};
use plio_qic_model::Qic;
use plio_tx_model::{BackplaneSample, PlioTx, PtiDirection, QicPtiDrive};
use pti_model::{encode_control, encode_data_beat, ControlImage, Token, TokenKind};
use qli_model::{DeviceToQic, DmaDirection, DmaRequest, DmaStatus, DmaWord, MmioResponse, NotificationRequest};

fn idle() -> Token { Token::new(TokenKind::Idle, 0, 0).unwrap() }

fn clock_slot(tx: &mut PlioTx, q: QicPtiDrive, bus: BackplaneSample) {
    let _ = tx.drive(false, q, bus);
    tx.clock(false, q, bus);
}

fn qdrive(token: Token) -> QicPtiDrive {
    QicPtiDrive { token, ..QicPtiDrive::default() }
}

/// Encode one logical QIC output through the frozen PTI contract and return
/// the actual backplane image driven by PLIO-TX. Nothing below this helper is
/// allowed to inspect CardToBus when checking external pins.
fn through_tx(tx: &mut PlioTx, card: CardToBus) -> plio_tx_model::BackplaneDrive {
    let has_control = card.space.is_some() || card.address_strobe || card.data_strobe;
    let has_data = card.ad.is_some() || card.par.is_some();
    let drives_bus = has_control || has_data;

    // IDLE is the only legal PTI direction-change slot. The receive-side tests
    // leave PLIO-TX in TX_TO_QIC, so turn back before presenting outbound tokens.
    clock_slot(tx, qdrive(idle()), BackplaneSample::default());

    // PLIO-TX needs one control image for every driven transaction. A worker
    // read response can drive AD/PAR without driving the control pins, so emit
    // a metadata-only control token in that case.
    if drives_bus {
        let c = ControlImage {
            space: card.space.unwrap_or(Space::Worker) as u8,
            address_strobe: card.address_strobe,
            read: card.read,
            byte_enable: card.byte_enable,
            burst_len: card.burst.blen(),
            data_strobe: card.data_strobe,
            drive_ad_par: has_data,
            drive_control: has_control,
        };
        clock_slot(tx, qdrive(encode_control(c).unwrap()), BackplaneSample::default());
    }
    if let (Some(ad), Some(par)) = (card.ad, card.par) {
        for token in encode_data_beat(ad, par).unwrap() {
            clock_slot(tx, qdrive(token), BackplaneSample::default());
        }
    }

    // PTI requires an idle slot before a new TX_DRIVE assertion.
    clock_slot(tx, qdrive(idle()), BackplaneSample::default());

    let q = QicPtiDrive {
        token: idle(),
        drive_enable: drives_bus,
        response_enable: card.ack || card.err,
        response_ack: card.ack,
        response_err: card.err,
        bus_request: card.request,
        ..QicPtiDrive::default()
    };
    let (bp, obs) = tx.drive(false, q, BackplaneSample::default());
    assert!(!obs.protocol_fault, "legal QIC image caused PTI fault");
    assert!(!obs.contention);
    tx.clock(false, q, BackplaneSample::default());
    bp
}

fn sample_ad_through_tx(tx: &mut PlioTx, ad: u32, par: u8) -> (u32, u8) {
    let bus = BackplaneSample { ad, par, ..BackplaneSample::default() };
    let turn = QicPtiDrive { direction: PtiDirection::TxToQic, token: idle(), ..QicPtiDrive::default() };
    clock_slot(tx, turn, bus);

    let loq = QicPtiDrive { direction: PtiDirection::TxToQic, token: Token::new(TokenKind::DataLo, 0, 0).unwrap(), ..QicPtiDrive::default() };
    let (_, lo) = tx.drive(false, loq, bus);
    tx.clock(false, loq, bus);
    let lot = lo.rx_token.expect("low receive bank");

    // Change the live backplane deliberately: HI must still come from the LO capture.
    let changed = BackplaneSample { ad: !ad, par: !par & 0xf, ..bus };
    let hiq = QicPtiDrive { direction: PtiDirection::TxToQic, token: Token::new(TokenKind::DataHi, 0, 0).unwrap(), ..QicPtiDrive::default() };
    let (_, hi) = tx.drive(false, hiq, changed);
    tx.clock(false, hiq, changed);
    let hit = hi.rx_token.expect("high receive bank");
    (u32::from(lot.data()) | (u32::from(hit.data()) << 16), lot.parity() | (hit.parity() << 2))
}

#[test]
fn worker_read_response_reaches_backplane_only_through_tx() {
    let mut qic = Qic::new();
    let mut tx = PlioTx::new();
    let address = 0x100;
    let (rx_ad, rx_par) = sample_ad_through_tx(&mut tx, address, odd_parity_32(address));
    assert_eq!((rx_ad, rx_par), (address, odd_parity_32(address)));

    let mut bus = BusToCard { selected: true, ad: Some(rx_ad), par: Some(rx_par), space: Some(Space::Worker), address_strobe: true, read: true, byte_enable: 0xf, burst: BurstWords::One, ..Default::default() };
    let mut dev = DeviceToQic::default();
    let (card, _) = qic.drive(&bus, &dev);
    let bp = through_tx(&mut tx, card);
    assert_eq!(bp.response, Some((true, false)));
    qic.clock(&bus, &dev);

    bus = BusToCard { data_strobe: true, ..Default::default() };
    qic.clock(&bus, &dev);
    dev.mmio_ready = true;
    qic.clock(&BusToCard::default(), &dev);
    dev.mmio_response = Some(MmioResponse::ReadOk(0x89ab_cdef));
    bus.data_strobe = true;
    let (card, _) = qic.drive(&bus, &dev);
    let bp = through_tx(&mut tx, card);
    assert_eq!(bp.ad_par, Some((0x89ab_cdef, odd_parity_32(0x89ab_cdef))));
    assert_eq!(bp.response, Some((true, false)));
}

#[test]
fn dma_and_notification_manager_images_cross_pti_tx() {
    for (direction, expect_read) in [(DmaDirection::HostToDevice, true), (DmaDirection::DeviceToHost, false)] {
        let mut qic = Qic::new();
        let mut tx = PlioTx::new();
        let dev = DeviceToQic { dma_request: Some(DmaRequest { direction, address: 0x1234_5000, words: BurstWords::Four }), ..Default::default() };
        qic.clock(&BusToCard::default(), &dev);
        let grant = BusToCard { grant: true, ..Default::default() };
        let (br, _) = qic.drive(&grant, &dev);
        assert!(through_tx(&mut tx, br).request);
        qic.clock(&grant, &dev);
        let (address, _) = qic.drive(&grant, &dev);
        let bp = through_tx(&mut tx, address);
        assert_eq!(bp.ad_par, Some((0x1234_5000, odd_parity_32(0x1234_5000))));
        assert_eq!(bp.control.unwrap().space, Space::HostDma as u8);
        assert_eq!(bp.control.unwrap().read, expect_read);
        assert!(bp.control.unwrap().address_strobe);
    }

    let mut qic = Qic::new();
    let mut tx = PlioTx::new();
    let dev = DeviceToQic { notification_request: Some(NotificationRequest { channel: 3 }), ..Default::default() };
    qic.clock(&BusToCard::default(), &dev);
    let grant = BusToCard { grant: true, ..Default::default() };
    qic.clock(&grant, &dev);
    let (address, _) = qic.drive(&grant, &dev);
    let bp = through_tx(&mut tx, address);
    assert_eq!(bp.ad_par, Some((12, odd_parity_32(12))));
    assert_eq!(bp.control.unwrap().space, Space::Controller as u8);
    assert!(bp.control.unwrap().address_strobe);

    qic.clock(&BusToCard { grant: true, ack: true, ..Default::default() }, &dev);
    let data_bus = BusToCard { grant: true, ack: true, ..Default::default() };
    let (data, qo) = qic.drive(&data_bus, &dev);
    let bp = through_tx(&mut tx, data);
    assert_eq!(bp.ad_par, Some((0, odd_parity_32(0))));
    assert!(bp.control.unwrap().data_strobe);
    assert!(qo.notification_ready);
}

#[test]
fn device_to_host_wait_holds_same_external_word_and_bus_error_reports_progress() {
    let mut qic = Qic::new();
    let mut tx = PlioTx::new();
    let mut dev = DeviceToQic { dma_request: Some(DmaRequest { direction: DmaDirection::DeviceToHost, address: 0x2000, words: BurstWords::Four }), ..Default::default() };
    qic.clock(&BusToCard::default(), &dev);
    let grant = BusToCard { grant: true, ..Default::default() };
    qic.clock(&grant, &dev);
    qic.clock(&BusToCard { grant: true, ack: true, ..Default::default() }, &dev);

    dev.dma_write = Some(DmaWord { data: 0x1111_1111 });
    qic.clock(&grant, &dev);
    let (card1, _) = qic.drive(&grant, &dev);
    let bp1 = through_tx(&mut tx, card1);
    let (card2, _) = qic.drive(&grant, &dev);
    let bp2 = through_tx(&mut tx, card2);
    assert_eq!(bp1.ad_par, bp2.ad_par);
    assert_eq!(bp1.ad_par, Some((0x1111_1111, odd_parity_32(0x1111_1111))));

    qic.clock(&BusToCard { grant: true, ack: true, ..Default::default() }, &dev);
    dev.dma_write = Some(DmaWord { data: 0x2222_2222 });
    qic.clock(&grant, &dev);
    qic.clock(&BusToCard { grant: true, err: true, ..Default::default() }, &dev);
    let (_, qo) = qic.drive(&BusToCard::default(), &dev);
    let c = qo.dma_completion.expect("partial completion");
    assert_eq!(c.status, DmaStatus::BusError);
    assert_eq!(c.words_completed, 1);
}

#[test]
fn host_to_device_bad_parity_never_reaches_qli_and_reset_kills_tx_drive() {
    let mut qic = Qic::new();
    let mut tx = PlioTx::new();
    let dev = DeviceToQic { dma_request: Some(DmaRequest { direction: DmaDirection::HostToDevice, address: 0x3000, words: BurstWords::One }), ..Default::default() };
    qic.clock(&BusToCard::default(), &dev);
    let grant = BusToCard { grant: true, ..Default::default() };
    qic.clock(&grant, &dev);
    qic.clock(&BusToCard { grant: true, ack: true, ..Default::default() }, &dev);

    let word = 0xa5a5_5a5a;
    let (rx, goodp) = sample_ad_through_tx(&mut tx, word, odd_parity_32(word) ^ 1);
    qic.clock(&BusToCard { grant: true, ack: true, ad: Some(rx), par: Some(goodp), ..Default::default() }, &dev);
    let (_, qo) = qic.drive(&grant, &dev);
    assert!(qo.dma_read.is_none());
    let (_, qo) = qic.drive(&BusToCard::default(), &dev);
    assert_eq!(qo.dma_completion.unwrap().status, DmaStatus::ParityError);

    let card = CardToBus { request: true, ad: Some(0xdead_beef), par: Some(odd_parity_32(0xdead_beef)), space: Some(Space::HostDma), data_strobe: true, byte_enable: 0xf, ..Default::default() };
    let _ = through_tx(&mut tx, card);
    let q = QicPtiDrive { token: idle(), drive_enable: true, bus_request: true, ..Default::default() };
    let (bp, _) = tx.drive(true, q, BackplaneSample::default());
    assert_eq!(bp, Default::default(), "RESET must immediately tri-state PLIO-TX");
}
