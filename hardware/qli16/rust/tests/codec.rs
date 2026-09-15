use plio_logical_model::BurstWords;
use qli16_model::codec::LinkCodec;
use qli16_model::{Direction, Token, TokenType};
use qli_model::{
    DeviceToQic, DmaCompletion, DmaDirection, DmaRequest, DmaStatus, MmioRequest,
    MmioResponse, NotificationRequest, QicToDevice,
};

#[test]
fn final_token_holds_until_semantic_ready() {
    let mut link = LinkCodec::new();
    let req = MmioRequest { address: 0x100, write: false, byte_enable: 0xf, write_data: 0 };
    let qic = QicToDevice { mmio_request: Some(req), ..Default::default() };
    let dev = DeviceToQic::default();
    let first = link.cycle(false, qic, dev);
    assert!(first.slots[0].ack);
    assert!(!first.slots[1].ack);
    let held = first.slots[1].token;

    let second = link.cycle(false, qic, dev);
    assert_eq!(second.slots[0].token, held);
    assert!(!second.slots[0].ack);

    let ready = DeviceToQic { mmio_ready: true, ..Default::default() };
    let third = link.cycle(false, qic, ready);
    assert!(third.slots.iter().any(|s| s.valid && s.ack && s.token == held));
    assert_eq!(third.to_device.mmio_request, Some(req));
    assert!(third.to_qic.mmio_ready);
}

#[test]
fn opposite_direction_messages_have_at_least_one_idle_slot_between_them() {
    let mut link = LinkCodec::new();
    let first = link.cycle(
        false,
        QicToDevice { mmio_cancel: true, ..Default::default() },
        DeviceToQic::default(),
    );
    assert!(first.slots[0].valid);
    assert!(!first.slots[1].valid, "completed QIC->device message must leave an idle slot");

    let response = DeviceToQic { mmio_response: Some(MmioResponse::WriteOk), ..Default::default() };
    let qready = QicToDevice { mmio_response_ready: true, ..Default::default() };
    let second = link.cycle(false, qready, response);
    assert!(second.slots[0].valid);
    assert_eq!(second.slots[0].token.direction, Direction::DeviceToQic);
}

#[test]
fn notification_ready_crosses_back_as_completion_token() {
    let mut link = LinkCodec::new();
    let req = NotificationRequest { channel: 3 };
    let dev = DeviceToQic { notification_request: Some(req), ..Default::default() };
    let accepted = link.cycle(false, QicToDevice::default(), dev);
    assert_eq!(accepted.to_qic.notification_request, Some(req));

    let completed = link.cycle(
        false,
        QicToDevice { notification_ready: true, ..Default::default() },
        dev,
    );
    assert!(completed.slots.iter().any(|s| {
        s.valid
            && s.token.direction == Direction::QicToDevice
            && s.token.kind == TokenType::Notification
            && s.token.payload == 3
    }));
    assert!(completed.to_device.notification_ready);
}

#[test]
fn all_dma_burst_headers_cross_the_physical_link() {
    for words in [BurstWords::One, BurstWords::Four, BurstWords::Eight, BurstWords::Sixteen] {
        let mut link = LinkCodec::new();
        let req = DmaRequest { direction: DmaDirection::DeviceToHost, address: 0x1000, words };
        let dev = DeviceToQic { dma_request: Some(req), ..Default::default() };
        let qic = QicToDevice { dma_request_ready: true, ..Default::default() };
        let mut seen = false;
        for _ in 0..3 {
            let c = link.cycle(false, qic, dev);
            seen |= c.to_qic.dma_request == Some(req);
        }
        assert!(seen, "DMA request did not complete for {words:?}");
    }
}

#[test]
fn dma_completion_and_malformed_reset_behavior() {
    let mut link = LinkCodec::new();
    let completion = DmaCompletion { status: DmaStatus::BusError, words_completed: 3 };
    let qic = QicToDevice { dma_completion: Some(completion), ..Default::default() };
    let dev = DeviceToQic { dma_completion_ready: true, ..Default::default() };
    let c = link.cycle(false, qic, dev);
    assert_eq!(c.to_device.dma_completion, Some(completion));

    link.inject_raw_token(Token {
        kind: TokenType::Notification,
        payload: 0x8000,
        direction: Direction::DeviceToQic,
    });
    assert!(link.protocol_fault());
    let reset = link.cycle(true, QicToDevice::default(), DeviceToQic::default());
    assert!(!reset.protocol_fault);
    assert!(reset.to_device.reset);
}
