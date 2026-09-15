use naked_card::{NakedDevice, CFG_DEVICE_CONTROL, CFG_ID, PLIO_ID};
use plio_logical_model::{odd_parity_32, BusToCard, BurstWords, CardToBus, Space};
use plio_qic_model::Qic;
use plio_testbench::{TestPeer, WorkerResult};
use plio_tx_model::{BackplaneDrive, BackplaneSample, PlioTx, PtiDirection, QicPtiDrive};
use pti_model::{encode_control, encode_data_beat, ControlImage, Token, TokenKind};
use qli16_model::codec::LinkCodec;
use qli_model::{
    DeviceToQic, DmaDirection, DmaRequest, DmaStatus, DmaWord, NotificationRequest,
    QicToDevice,
};

fn idle() -> Token { Token::new(TokenKind::Idle, 0, 0).unwrap() }

fn qdrive(token: Token) -> QicPtiDrive {
    QicPtiDrive { token, ..QicPtiDrive::default() }
}

fn clock_slot(tx: &mut PlioTx, q: QicPtiDrive, bus: BackplaneSample) {
    let (_, obs) = tx.drive(false, q, bus);
    assert!(!obs.protocol_fault, "PTI protocol fault before clock: {obs:?}");
    tx.clock(false, q, bus);
}

fn turn_qic_to_tx(tx: &mut PlioTx) {
    clock_slot(tx, qdrive(idle()), BackplaneSample::default());
}

fn through_tx(tx: &mut PlioTx, card: CardToBus) -> BackplaneDrive {
    // A direction change is legal only through IDLE. Always provide it; this
    // is deliberately stricter than relying on whatever the previous helper did.
    turn_qic_to_tx(tx);

    let has_control = card.space.is_some() || card.address_strobe || card.data_strobe;
    let has_data = card.ad.is_some() || card.par.is_some();
    if has_control {
        let control = ControlImage {
            space: card.space.unwrap_or(Space::Worker) as u8,
            address_strobe: card.address_strobe,
            read: card.read,
            byte_enable: card.byte_enable,
            burst_len: card.burst.blen(),
            data_strobe: card.data_strobe,
            drive_ad_par: has_data,
            drive_control: true,
        };
        clock_slot(tx, qdrive(encode_control(control).unwrap()), BackplaneSample::default());
    }
    if let (Some(ad), Some(par)) = (card.ad, card.par) {
        for t in encode_data_beat(ad, par).unwrap() {
            clock_slot(tx, qdrive(t), BackplaneSample::default());
        }
    }
    clock_slot(tx, qdrive(idle()), BackplaneSample::default());

    let q = QicPtiDrive {
        token: idle(),
        drive_enable: has_control,
        response_enable: card.ack || card.err,
        response_ack: card.ack,
        response_err: card.err,
        bus_request: card.request,
        ..QicPtiDrive::default()
    };
    let (bp, obs) = tx.drive(false, q, BackplaneSample::default());
    assert!(!obs.protocol_fault, "legal QIC image caused PLIO-TX fault");
    tx.clock(false, q, BackplaneSample::default());
    bp
}

fn sample_ad(tx: &mut PlioTx, ad: u32, par: u8) -> (u32, u8) {
    let bus = BackplaneSample { ad, par, ..Default::default() };
    let turn = QicPtiDrive { direction: PtiDirection::TxToQic, token: idle(), ..Default::default() };
    clock_slot(tx, turn, bus);

    let loq = QicPtiDrive {
        direction: PtiDirection::TxToQic,
        token: Token::new(TokenKind::DataLo, 0, 0).unwrap(),
        ..Default::default()
    };
    let (_, lo) = tx.drive(false, loq, bus);
    tx.clock(false, loq, bus);
    let lot = lo.rx_token.expect("low receive bank");

    let hiq = QicPtiDrive {
        direction: PtiDirection::TxToQic,
        token: Token::new(TokenKind::DataHi, 0, 0).unwrap(),
        ..Default::default()
    };
    let (_, hi) = tx.drive(false, hiq, bus);
    tx.clock(false, hiq, bus);
    let hit = hi.rx_token.expect("high receive bank");
    (
        u32::from(lot.data()) | (u32::from(hit.data()) << 16),
        lot.parity() | (hit.parity() << 2),
    )
}

fn physicalize_bus(tx: &mut PlioTx, mut bus: BusToCard) -> BusToCard {
    if let (Some(ad), Some(par)) = (bus.ad, bus.par) {
        let (sampled, sampled_par) = sample_ad(tx, ad, par);
        bus.ad = Some(sampled);
        bus.par = Some(sampled_par);
    }
    bus
}

fn card_from_backplane(bp: BackplaneDrive) -> CardToBus {
    let mut card = CardToBus { request: bp.request, ..Default::default() };
    if let Some((ad, par)) = bp.ad_par {
        card.ad = Some(ad);
        card.par = Some(par);
    }
    if let Some(c) = bp.control {
        card.space = match c.space {
            0 => Some(Space::Worker),
            1 => Some(Space::HostDma),
            2 => Some(Space::Controller),
            _ => Some(Space::Reserved),
        };
        card.address_strobe = c.address_strobe;
        card.read = c.read;
        card.byte_enable = c.byte_enable;
        card.burst = BurstWords::from_blen(c.burst_len).unwrap();
        card.data_strobe = c.data_strobe;
    }
    if let Some((ack, err)) = bp.response {
        card.ack = ack;
        card.err = err;
    }
    card
}

fn worker_cycle(
    qic: &mut Qic,
    link: &mut LinkCodec,
    tx: &mut PlioTx,
    dev: &mut NakedDevice,
    peer: &mut TestPeer,
) {
    let bus = physicalize_bus(tx, peer.bus_inputs());
    let device = dev.drive();

    // QIC semantic outputs do not depend on the final QLI handshake for the
    // worker path, so the empty preview is sufficient here.
    let (_, qout) = qic.drive(&bus, &DeviceToQic::default());
    let local = link.cycle(bus.reset, qout, device);
    assert!(!local.protocol_fault);

    let (card, _) = qic.drive(&bus, &local.to_qic);
    let physical_card = card_from_backplane(through_tx(tx, card));
    peer.clock(&physical_card);
    dev.clock(&local.to_device);
    qic.clock(&bus, &local.to_qic);
}

#[test]
fn naked_worker_read_write_and_error_cross_every_boundary() {
    let mut qic = Qic::new();
    let mut link = LinkCodec::new();
    let mut tx = PlioTx::new();
    let mut dev = NakedDevice::new();
    let mut peer = TestPeer::new();

    peer.start_worker_read(CFG_ID, 0xf);
    for _ in 0..64 {
        worker_cycle(&mut qic, &mut link, &mut tx, &mut dev, &mut peer);
        if peer.worker_result().is_some() { break; }
    }
    assert_eq!(peer.worker_result(), Some(WorkerResult::Read(PLIO_ID)));

    peer.start_worker_write(CFG_DEVICE_CONTROL, 0xf, 0x1234_5678);
    for _ in 0..64 {
        worker_cycle(&mut qic, &mut link, &mut tx, &mut dev, &mut peer);
        if peer.worker_result().is_some() { break; }
    }
    assert_eq!(peer.worker_result(), Some(WorkerResult::WriteOk));

    peer.start_worker_read(0x80, 0xf);
    for _ in 0..64 {
        worker_cycle(&mut qic, &mut link, &mut tx, &mut dev, &mut peer);
        if peer.worker_result().is_some() { break; }
    }
    assert_eq!(peer.worker_result(), Some(WorkerResult::Error));
}

fn run_dma(direction: DmaDirection, words: BurstWords, error_beat: Option<u8>, bad_parity_beat: Option<u8>) -> (DmaStatus, u8, Vec<u32>) {
    let mut qic = Qic::new();
    let mut link = LinkCodec::new();
    let mut tx = PlioTx::new();
    let mut peer = TestPeer::new();
    peer.dma_error_beat = error_beat;
    peer.dma_bad_parity_beat = bad_parity_beat;
    peer.dma_read_base = 0x7000_0000;

    let request = DmaRequest { direction, address: 0x1234_5000, words };
    let mut request_pending = true;
    let mut write_index = 0u8;
    let mut received = Vec::new();
    let mut final_status = None;

    for _cycle in 0..512 {
        let bus = physicalize_bus(&mut tx, peer.bus_inputs());

        let mut device = DeviceToQic::default();
        device.dma_completion_ready = true;
        if request_pending { device.dma_request = Some(request); }
        if !request_pending && direction == DmaDirection::DeviceToHost && write_index < words.words() {
            device.dma_write = Some(DmaWord { data: 0x4000_0000 + u32::from(write_index) * 4 });
        }
        if direction == DmaDirection::HostToDevice { device.dma_read_ready = true; }

        // Physical DMA request decoding can present the complete candidate to
        // the semantic QIC combinationally while the final DMA_HEADER waits for
        // LACK. Clocking still uses only the accepted physical result below.
        let preview = if request_pending {
            DeviceToQic { dma_request: Some(request), ..DeviceToQic::default() }
        } else {
            DeviceToQic::default()
        };
        let (_, qout) = qic.drive(&bus, &preview);
        let local = link.cycle(false, qout, device);
        assert!(!local.protocol_fault);

        if local.to_device.dma_request_ready { request_pending = false; }
        if local.to_device.dma_write_ready { write_index += 1; }
        if let Some(word) = local.to_device.dma_read { received.push(word.data); }
        if let Some(c) = local.to_device.dma_completion {
            final_status = Some((c.status, c.words_completed));
        }

        let (card, _) = qic.drive(&bus, &local.to_qic);
        let physical_card = card_from_backplane(through_tx(&mut tx, card));
        peer.clock(&physical_card);
        qic.clock(&bus, &local.to_qic);

        if final_status.is_some() { break; }
    }

    let (status, completed) = final_status.expect("DMA completion did not cross QLI-16");
    (status, completed, received)
}

#[test]
fn both_dma_directions_and_all_burst_sizes_cross_qli16_and_plio_tx() {
    for words in [BurstWords::One, BurstWords::Four, BurstWords::Eight, BurstWords::Sixteen] {
        let (status, completed, _) = run_dma(DmaDirection::DeviceToHost, words, None, None);
        assert_eq!(status, DmaStatus::Ok);
        assert_eq!(completed, words.words());

        let (status, completed, received) = run_dma(DmaDirection::HostToDevice, words, None, None);
        assert_eq!(status, DmaStatus::Ok);
        assert_eq!(completed, words.words());
        assert_eq!(received.len(), usize::from(words.words()));
    }
}

#[test]
fn dma_bus_error_and_bad_parity_preserve_exact_partial_progress() {
    let (status, completed, _) = run_dma(DmaDirection::DeviceToHost, BurstWords::Four, Some(2), None);
    assert_eq!(status, DmaStatus::BusError);
    assert_eq!(completed, 2);

    let (status, completed, received) = run_dma(DmaDirection::HostToDevice, BurstWords::Four, None, Some(1));
    assert_eq!(status, DmaStatus::ParityError);
    assert_eq!(completed, 1);
    assert_eq!(received.len(), 1, "bad parity word must not cross QLI-16");
}

#[test]
fn notification_request_and_completion_cross_same_physical_qli16_link() {
    let mut qic = Qic::new();
    let mut link = LinkCodec::new();
    let mut tx = PlioTx::new();
    let mut peer = TestPeer::new();
    let request = NotificationRequest { channel: 2 };
    let mut completed = false;
    let mut transported = false;

    for _ in 0..128 {
        let bus = physicalize_bus(&mut tx, peer.bus_inputs());
        let device = DeviceToQic { notification_request: Some(request), ..Default::default() };
        let preview = if transported {
            DeviceToQic { notification_request: Some(request), ..Default::default() }
        } else {
            DeviceToQic::default()
        };
        let (_, qout) = qic.drive(&bus, &preview);
        let local = link.cycle(false, qout, device);
        transported |= local.to_qic.notification_request == Some(request);
        completed |= local.to_device.notification_ready;

        let (card, _) = qic.drive(&bus, &local.to_qic);
        peer.clock(&card_from_backplane(through_tx(&mut tx, card)));
        qic.clock(&bus, &local.to_qic);

        if completed { break; }
    }

    assert!(completed, "QLI-16 Notification completion never returned to device");
    assert_eq!(peer.notifications(), &[2]);
}

#[test]
fn reset_and_malformed_qli16_are_local_and_safe() {
    let mut link = LinkCodec::new();
    link.inject_raw_token(qli16_model::Token {
        kind: qli16_model::TokenType::Notification,
        payload: 0x8000,
        direction: qli16_model::Direction::DeviceToQic,
    });
    assert!(link.protocol_fault());
    let reset = link.cycle(true, QicToDevice::default(), DeviceToQic::default());
    assert!(!reset.protocol_fault);
    assert!(reset.to_device.reset);

    let mut tx = PlioTx::new();
    let q = QicPtiDrive { token: idle(), drive_enable: true, bus_request: true, ..Default::default() };
    let (bp, _) = tx.drive(true, q, BackplaneSample::default());
    assert_eq!(bp, BackplaneDrive::default(), "reset must tri-state PLIO-TX");
}
