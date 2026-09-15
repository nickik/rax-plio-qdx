use plio_logical_model::BurstWords;
use qdx_a_model::{
    EndpointIn, QdxA, QdxACompletion, QdxAState, REG_CQ_BASE, REG_CQ_SIZE,
    REG_QDX_CONTROL, REG_SQ_BASE, REG_SQ_SIZE, REG_SQ_TAIL,
};
use qli_model::{
    DmaCompletion, DmaDirection, DmaStatus, DmaWord, MmioRequest, MmioResponse, QicToDevice,
};

fn emit(step: u8, event: &str, chip: &QdxA) {
    println!(
        "QDXATRACE|v1|step={step:02}|event={event}|state={}|sqh={}|sqt={}|cqh={}|cqt={}|err={}",
        chip.state().trace_name(),
        chip.sq_head(),
        chip.sq_tail(),
        chip.cq_head(),
        chip.cq_tail(),
        chip.error().code(),
    );
}

fn mmio_write(address: u32, byte_enable: u8, data: u32) -> QicToDevice {
    QicToDevice {
        mmio_request: Some(MmioRequest {
            address,
            write: true,
            byte_enable,
            write_data: data,
        }),
        ..Default::default()
    }
}

fn write_reg(chip: &mut QdxA, address: u32, byte_enable: u8, data: u32) {
    let request = mmio_write(address, byte_enable, data);
    assert!(chip.qic_port(&request).mmio_ready);
    chip.advance(&request, &EndpointIn::default());
    assert_eq!(chip.qic_port(&QicToDevice::default()).mmio_response, Some(MmioResponse::WriteOk));
    chip.advance(
        &QicToDevice { mmio_response_ready: true, ..Default::default() },
        &EndpointIn::default(),
    );
}

fn main() {
    let mut chip = QdxA::new();

    chip.advance(
        &QicToDevice { reset: true, ..Default::default() },
        &EndpointIn::default(),
    );
    assert_eq!(chip.state(), QdxAState::Disabled);
    emit(0, "reset", &chip);

    write_reg(&mut chip, REG_SQ_BASE, 0xf, 0x1200_1000);
    write_reg(&mut chip, REG_SQ_SIZE, 0x3, 4);
    write_reg(&mut chip, REG_CQ_BASE, 0xf, 0x2300_2000);
    write_reg(&mut chip, REG_CQ_SIZE, 0x3, 4);
    write_reg(&mut chip, REG_QDX_CONTROL, 0xf, 0x5);
    assert_eq!(chip.state(), QdxAState::ReadyIdle);
    emit(1, "configured", &chip);

    write_reg(&mut chip, REG_SQ_TAIL, 0x3, 1);
    assert_eq!(chip.state(), QdxAState::ReadyIdle);
    chip.advance(&QicToDevice::default(), &EndpointIn::default());
    assert_eq!(chip.state(), QdxAState::SqRequest);
    let sq = chip.qic_port(&QicToDevice::default()).dma_request.expect("SQ request");
    assert_eq!(sq.direction, DmaDirection::HostToDevice);
    assert_eq!(sq.address, 0x1200_1000);
    assert_eq!(sq.words, BurstWords::Eight);
    emit(2, "sq_request", &chip);

    chip.advance(
        &QicToDevice { dma_request_ready: true, ..Default::default() },
        &EndpointIn::default(),
    );
    for word in 0..8u32 {
        assert!(chip.qic_port(&QicToDevice::default()).dma_read_ready);
        chip.advance(
            &QicToDevice {
                dma_read: Some(DmaWord { data: 0xa000_0000 + word }),
                ..Default::default()
            },
            &EndpointIn::default(),
        );
    }
    assert!(chip.qic_port(&QicToDevice::default()).dma_completion_ready);
    chip.advance(
        &QicToDevice {
            dma_completion: Some(DmaCompletion { status: DmaStatus::Ok, words_completed: 8 }),
            ..Default::default()
        },
        &EndpointIn::default(),
    );
    let endpoint = chip.endpoint_port(&QicToDevice::default());
    let command = endpoint.command.expect("endpoint command");
    assert_eq!(command[0], 0xa000_0000);
    assert_eq!(command[7], 0xa000_0007);
    emit(3, "endpoint_offer", &chip);

    chip.advance(
        &QicToDevice::default(),
        &EndpointIn { command_ready: true, ..Default::default() },
    );
    assert!(chip.endpoint_port(&QicToDevice::default()).completion_ready);
    emit(4, "endpoint_wait", &chip);

    let completion: QdxACompletion = [0xc001_0000, 0xc001_0001, 0xc001_0002, 0xc001_0003];
    chip.advance(
        &QicToDevice::default(),
        &EndpointIn { completion: Some(completion), ..Default::default() },
    );
    let cq = chip.qic_port(&QicToDevice::default()).dma_request.expect("CQ request");
    assert_eq!(cq.direction, DmaDirection::DeviceToHost);
    assert_eq!(cq.address, 0x2300_2000);
    assert_eq!(cq.words, BurstWords::Four);
    emit(5, "cq_request", &chip);

    chip.advance(
        &QicToDevice { dma_request_ready: true, ..Default::default() },
        &EndpointIn::default(),
    );
    for expected in completion {
        let word = chip.qic_port(&QicToDevice::default()).dma_write.expect("CQ DMA word");
        assert_eq!(word.data, expected);
        chip.advance(
            &QicToDevice { dma_write_ready: true, ..Default::default() },
            &EndpointIn::default(),
        );
    }
    assert!(chip.qic_port(&QicToDevice::default()).dma_completion_ready);
    chip.advance(
        &QicToDevice {
            dma_completion: Some(DmaCompletion { status: DmaStatus::Ok, words_completed: 4 }),
            ..Default::default()
        },
        &EndpointIn::default(),
    );
    assert_eq!(chip.state(), QdxAState::Notify);
    assert_eq!(chip.cq_tail(), 1);
    emit(6, "cq_published", &chip);

    let notification = chip.qic_port(&QicToDevice::default()).notification_request.expect("notification");
    assert_eq!(notification.channel, 0);
    emit(7, "notification", &chip);
    chip.advance(
        &QicToDevice { notification_ready: true, ..Default::default() },
        &EndpointIn::default(),
    );

    assert_eq!(chip.state(), QdxAState::ReadyIdle);
    assert_eq!(chip.sq_head(), 1);
    assert_eq!(chip.sq_tail(), 1);
    assert_eq!(chip.cq_head(), 0);
    assert_eq!(chip.cq_tail(), 1);
    emit(8, "done", &chip);
}
