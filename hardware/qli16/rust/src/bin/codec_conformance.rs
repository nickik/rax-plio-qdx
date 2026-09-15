use qli16_model::codec::LinkCodec;
use qli16_model::{Direction, Token, TokenType};
use qli_model::{
    DeviceToQic, DmaCompletion, DmaDirection, DmaRequest, DmaStatus, MmioRequest,
    MmioResponse, NotificationRequest, QicToDevice,
};
use plio_logical_model::BurstWords;

fn emit(c: u8, result: &qli16_model::codec::CycleResult) {
    for (s, slot) in result.slots.iter().enumerate() {
        println!(
            "Q16TRACE|v1|c={c:02x}|s={s}|v={}|a={}|d={}|t={}|ld={:04x}",
            slot.valid as u8,
            slot.ack as u8,
            match slot.token.direction { Direction::QicToDevice => 0, Direction::DeviceToQic => 1 },
            slot.token.kind as u8,
            slot.token.payload,
        );
    }
    println!(
        "Q16RESULT|v1|c={c:02x}|mr={}|mrv={}|drq={}|drr={}|dw={}|dc={}|nv={}|nr={}|fault={}",
        result.to_qic.mmio_ready as u8,
        result.to_qic.mmio_response.is_some() as u8,
        result.to_qic.dma_request.is_some() as u8,
        result.to_qic.dma_read_ready as u8,
        result.to_qic.dma_write.is_some() as u8,
        result.to_device.dma_completion.is_some() as u8,
        result.to_qic.notification_request.is_some() as u8,
        result.to_device.notification_ready as u8,
        result.protocol_fault as u8,
    );
}

fn main() {
    let mut link = LinkCodec::new();
    let mmio = MmioRequest { address: 0x100, write: false, byte_enable: 0xf, write_data: 0 };

    emit(0, &link.cycle(true, QicToDevice::default(), DeviceToQic::default()));

    emit(1, &link.cycle(
        false,
        QicToDevice { mmio_request: Some(mmio), ..Default::default() },
        DeviceToQic::default(),
    ));
    emit(2, &link.cycle(
        false,
        QicToDevice { mmio_request: Some(mmio), ..Default::default() },
        DeviceToQic { mmio_ready: true, ..Default::default() },
    ));

    let response = MmioResponse::ReadOk(0x89ab_cdef);
    emit(3, &link.cycle(
        false,
        QicToDevice::default(),
        DeviceToQic { mmio_response: Some(response), ..Default::default() },
    ));
    emit(4, &link.cycle(
        false,
        QicToDevice { mmio_response_ready: true, ..Default::default() },
        DeviceToQic { mmio_response: Some(response), ..Default::default() },
    ));

    let request = DmaRequest { direction: DmaDirection::DeviceToHost, address: 0x1234_5000, words: BurstWords::Four };
    emit(5, &link.cycle(
        false,
        QicToDevice { dma_request_ready: true, ..Default::default() },
        DeviceToQic { dma_request: Some(request), ..Default::default() },
    ));
    emit(6, &link.cycle(
        false,
        QicToDevice { dma_request_ready: true, ..Default::default() },
        DeviceToQic { dma_request: Some(request), ..Default::default() },
    ));

    let completion = DmaCompletion { status: DmaStatus::BusError, words_completed: 3 };
    emit(7, &link.cycle(
        false,
        QicToDevice { dma_completion: Some(completion), ..Default::default() },
        DeviceToQic { dma_completion_ready: true, ..Default::default() },
    ));

    let notification = NotificationRequest { channel: 3 };
    emit(8, &link.cycle(
        false,
        QicToDevice::default(),
        DeviceToQic { notification_request: Some(notification), ..Default::default() },
    ));
    emit(9, &link.cycle(
        false,
        QicToDevice { notification_ready: true, ..Default::default() },
        DeviceToQic { notification_request: Some(notification), ..Default::default() },
    ));

    link.inject_raw_token(Token {
        kind: TokenType::Notification,
        payload: 0x8000,
        direction: Direction::DeviceToQic,
    });
    emit(10, &link.cycle(false, QicToDevice::default(), DeviceToQic::default()));
    emit(11, &link.cycle(true, QicToDevice::default(), DeviceToQic::default()));
}
