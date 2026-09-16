use memory_controller_model::{ControllerState, FakeMemory, MemoryController, MemoryRequest};
use plio_host_core_model::{CoreInput, MemoryInput, PLIOHostCore};
use plio_host_dma_model::{DmaError, MemoryResponse};
use plio_logical_model::{odd_parity_32, BurstWords, CardToBus, Space};

fn state_code(state: ControllerState) -> u8 {
    match state {
        ControllerState::Idle => 0,
        ControllerState::BackendRequest => 1,
        ControllerState::BackendResponse => 2,
        ControllerState::HostResponse => 3,
    }
}

fn response_code(response: Option<MemoryResponse>) -> u8 {
    match response {
        None => 0,
        Some(MemoryResponse::ReadData(_)) => 1,
        Some(MemoryResponse::WriteDone) => 2,
        Some(MemoryResponse::Fault) => 3,
    }
}

fn emit_idle(controller: &MemoryController) {
    let debug = controller.debug();
    println!(
        "MEMCTRLTRACE|v2|case=idle|state={}|host_ready={}|backend_valid={}|write=0|address=00000000|be=0|response={}",
        state_code(debug.state),
        u8::from(debug.host_request_ready),
        u8::from(debug.backend_request_valid),
        response_code(controller.host_response())
    );
}

fn emit_request(label: &str, controller: &MemoryController, include_data: bool) {
    let debug = controller.debug();
    let request = controller.backend_request().expect("backend request must be exposed");
    if include_data {
        println!(
            "MEMCTRLTRACE|v2|case={label}|state={}|host_ready={}|backend_valid={}|write={}|address={:08x}|be={:x}|data={:08x}|response={}",
            state_code(debug.state),
            u8::from(debug.host_request_ready),
            u8::from(debug.backend_request_valid),
            u8::from(request.is_write()),
            request.physical_address(),
            request.byte_enable(),
            request.write_data(),
            response_code(controller.host_response())
        );
    } else {
        println!(
            "MEMCTRLTRACE|v2|case={label}|state={}|host_ready={}|backend_valid={}|write={}|address={:08x}|be={:x}|response={}",
            state_code(debug.state),
            u8::from(debug.host_request_ready),
            u8::from(debug.backend_request_valid),
            u8::from(request.is_write()),
            request.physical_address(),
            request.byte_enable(),
            response_code(controller.host_response())
        );
    }
}

fn req_only() -> CardToBus { CardToBus { request: true, ..CardToBus::default() } }

fn dma_address(address: u32, read: bool) -> CardToBus {
    CardToBus {
        request: true,
        ad: Some(address),
        par: Some(odd_parity_32(address)),
        space: Some(Space::HostDma),
        address_strobe: true,
        read,
        byte_enable: 0xf,
        burst: BurstWords::One,
        ..CardToBus::default()
    }
}

fn dma_data(value: u32) -> CardToBus {
    CardToBus {
        request: true,
        ad: Some(value),
        par: Some(odd_parity_32(value)),
        data_strobe: true,
        byte_enable: 0xf,
        ..CardToBus::default()
    }
}

fn host_cycle(
    host: &mut PLIOHostCore,
    controller: &mut MemoryController,
    memory: &mut FakeMemory,
    cards: [CardToBus; 8],
) -> plio_host_core_model::CoreOutput {
    let request_ready = controller.host_request_ready();
    let response = controller.host_response();
    let output = host.step(CoreInput {
        cards,
        memory: MemoryInput { request_ready, response },
        ..CoreInput::default()
    });

    if response.is_some() {
        assert!(controller.consume_host_response());
    }
    if request_ready {
        if let Some(request) = output.memory_request {
            assert!(controller.accept_host_request(MemoryRequest::from_plio(request)));
        }
    }
    controller.tick_backend(memory);
    output
}

fn main() {
    let mut c = MemoryController::new();
    emit_idle(&c);

    assert!(c.accept_host_request(MemoryRequest::read(0x100, 0xf)));
    emit_request("read_request", &c, false);
    assert_eq!(c.backend_request().map(|r| r.byte_enable()), Some(0xf));
    assert!(c.backend_request_accepted());
    assert!(c.accept_backend_response(MemoryResponse::ReadData(0x1122_3344)));
    assert_eq!(c.host_response(), Some(MemoryResponse::ReadData(0x1122_3344)));
    assert!(c.consume_host_response());

    assert!(c.accept_host_request(MemoryRequest::write(0x104, 0x5, 0xaabb_ccdd)));
    emit_request("write_request", &c, true);
    assert_eq!(c.backend_request().map(|r| r.byte_enable()), Some(0x5));
    assert!(c.backend_request_accepted());
    assert!(c.accept_backend_response(MemoryResponse::WriteDone));
    assert_eq!(c.host_response(), Some(MemoryResponse::WriteDone));
    assert!(c.consume_host_response());

    assert!(c.accept_host_request(MemoryRequest::read(0x102, 0xf)));
    assert_eq!(c.host_response(), Some(MemoryResponse::Fault));
    assert!(c.consume_host_response());

    assert!(c.accept_host_request(MemoryRequest::read(0x200, 0xf)));
    assert!(c.backend_request_accepted());
    assert!(c.accept_backend_response(MemoryResponse::Fault));
    assert_eq!(c.host_response(), Some(MemoryResponse::Fault));
    assert!(c.consume_host_response());

    assert!(c.accept_host_request(MemoryRequest::write(0x300, 0xa, 0xdead_beef)));
    assert_eq!(c.backend_request().map(|r| r.byte_enable()), Some(0xa));
    c.reset();
    assert_eq!(c.debug().state, ControllerState::Idle);
    assert_eq!(c.backend_request(), None);
    println!("MEMCTRLTRACE|v2|case=reset|status=ok|be=0");

    let mut host = PLIOHostCore::new();
    let mut controller = MemoryController::new();
    let mut memory = FakeMemory::new(1024, 2);
    assert!(memory.preload_word(0x100, 0x5566_7788));
    memory.set_request_holdoff(3);

    let generation = host.bind_dma(1, 3, 0x100, 0x100, true, true).unwrap();
    let read_handle = (3u32 << 28) | (u32::from(generation) << 24);
    let mut cards = [CardToBus::default(); 8];
    cards[1] = req_only();
    host_cycle(&mut host, &mut controller, &mut memory, cards);
    cards[1] = dma_address(read_handle, true);
    host_cycle(&mut host, &mut controller, &mut memory, cards);
    let address_ack = host_cycle(&mut host, &mut controller, &mut memory, cards);
    assert!(address_ack.buses[1].ack);

    let mut read_value = None;
    for _ in 0..32 {
        cards[1] = if host.debug().dma_state == plio_host_dma_model::DmaState::DeviceReadReady {
            CardToBus { request: true, data_strobe: true, ..CardToBus::default() }
        } else {
            req_only()
        };
        let out = host_cycle(&mut host, &mut controller, &mut memory, cards);
        if out.buses[1].ack && out.buses[1].ad.is_some() {
            read_value = out.buses[1].ad;
            break;
        }
    }
    assert_eq!(read_value, Some(0x5566_7788));
    assert_eq!(host.take_dma_completion(), Some(Ok(1)));
    println!("MEMHOSTTRACE|v2|case=dma_read|status=ok|value=55667788|backend=fake|be=f");

    let write_handle = read_handle | 4;
    cards = [CardToBus::default(); 8];
    cards[1] = req_only();
    host_cycle(&mut host, &mut controller, &mut memory, cards);
    cards[1] = dma_address(write_handle, false);
    host_cycle(&mut host, &mut controller, &mut memory, cards);
    let address_ack = host_cycle(&mut host, &mut controller, &mut memory, cards);
    assert!(address_ack.buses[1].ack);
    cards[1] = dma_data(0xcafe_babe);
    host_cycle(&mut host, &mut controller, &mut memory, cards);

    let mut write_acked = false;
    for _ in 0..32 {
        cards[1] = req_only();
        let out = host_cycle(&mut host, &mut controller, &mut memory, cards);
        if out.buses[1].ack {
            write_acked = true;
            break;
        }
    }
    assert!(write_acked);
    assert_eq!(memory.peek_word(0x104), Some(0xcafe_babe));
    assert_eq!(host.take_dma_completion(), Some(Ok(1)));
    println!("MEMHOSTTRACE|v2|case=dma_write|status=ok|value=cafebabe|backend=fake|be=f");

    let fault_generation = host.bind_dma(1, 4, 0x4000, 0x100, true, false).unwrap();
    let fault_handle = (4u32 << 28) | (u32::from(fault_generation) << 24);
    cards = [CardToBus::default(); 8];
    cards[1] = req_only();
    host_cycle(&mut host, &mut controller, &mut memory, cards);
    cards[1] = dma_address(fault_handle, true);
    host_cycle(&mut host, &mut controller, &mut memory, cards);
    assert!(host_cycle(&mut host, &mut controller, &mut memory, cards).buses[1].ack);
    let mut saw_fault = false;
    for _ in 0..32 {
        cards[1] = req_only();
        let out = host_cycle(&mut host, &mut controller, &mut memory, cards);
        if out.buses[1].err {
            saw_fault = true;
            break;
        }
    }
    assert!(saw_fault);
    assert_eq!(host.take_dma_completion(), Some(Err(DmaError::MemoryFault)));
    println!("MEMHOSTTRACE|v2|case=backend_fault|status=memory_fault|backend=fake|be=f");

    println!("PASS memory controller Rust reference + PLIO host integration");
}
