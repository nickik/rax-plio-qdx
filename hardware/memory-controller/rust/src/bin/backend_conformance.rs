use memory_controller_model::{
    ControllerState, FakeMemory, MemoryBackend, MemoryController, MemoryRequest,
};
use plio_host_dma_model::MemoryResponse;

fn transact(
    controller: &mut MemoryController,
    memory: &mut FakeMemory,
    request: MemoryRequest,
) -> MemoryResponse {
    assert!(controller.accept_host_request(request));
    for _ in 0..128 {
        controller.tick_backend(memory);
        if let Some(response) = controller.host_response() {
            assert!(controller.consume_host_response());
            return response;
        }
    }
    panic!("memory transaction did not complete");
}

fn main() {
    let mut controller = MemoryController::new();
    let mut memory = FakeMemory::new(1024, 2);
    assert!(memory.preload_word(0x100, 0x1122_3344));
    assert!(memory.preload_word(0x104, 0x5566_7788));

    assert_eq!(
        transact(&mut controller, &mut memory, MemoryRequest::write(0x100, 0x5, 0xaabb_ccdd)),
        MemoryResponse::WriteDone
    );
    assert_eq!(memory.peek_word(0x100), Some(0x11bb_33dd));

    assert_eq!(
        transact(&mut controller, &mut memory, MemoryRequest::write(0x104, 0xa, 0xaabb_ccdd)),
        MemoryResponse::WriteDone
    );
    assert_eq!(memory.peek_word(0x104), Some(0xaa66_cc88));

    assert_eq!(
        transact(&mut controller, &mut memory, MemoryRequest::write(0x100, 0x0, 0xffff_ffff)),
        MemoryResponse::WriteDone
    );
    assert_eq!(memory.peek_word(0x100), Some(0x11bb_33dd));

    assert_eq!(
        transact(&mut controller, &mut memory, MemoryRequest::write(0x100, 0xf, 0xdead_beef)),
        MemoryResponse::WriteDone
    );
    assert_eq!(memory.peek_word(0x100), Some(0xdead_beef));

    // Read masks are retained for tracing but do not mask read data.
    assert_eq!(
        transact(&mut controller, &mut memory, MemoryRequest::read(0x100, 0x3)),
        MemoryResponse::ReadData(0xdead_beef)
    );
    println!("MEMBACKENDTRACE|v2|case=masked|status=ok|m5=11bb33dd|ma=aa66cc88|full=deadbeef");

    memory.set_request_holdoff(4);
    assert!(controller.accept_host_request(MemoryRequest::write(0x108, 0x6, 0x1234_5678)));
    for _ in 0..4 {
        assert_eq!(controller.backend_request().map(|r| r.byte_enable()), Some(0x6));
        assert_eq!(controller.backend_request().map(|r| r.write_data()), Some(0x1234_5678));
        controller.tick_backend(&mut memory);
    }
    while controller.host_response().is_none() {
        controller.tick_backend(&mut memory);
    }
    assert_eq!(controller.host_response(), Some(MemoryResponse::WriteDone));
    assert!(controller.consume_host_response());
    assert_eq!(memory.peek_word(0x108), Some(0x0034_5600));

    assert!(controller.accept_host_request(MemoryRequest::write(0x10c, 0x9, 0xcafe_babe)));
    while controller.debug().state != ControllerState::BackendResponse {
        controller.tick_backend(&mut memory);
    }
    assert_eq!(memory.response(), None);

    controller.reset();
    let mut saw_stale_backend_response = false;
    for _ in 0..16 {
        controller.tick_backend(&mut memory);
        assert_eq!(controller.debug().state, ControllerState::Idle);
        assert_eq!(controller.host_response(), None);
        if memory.response().is_some() {
            saw_stale_backend_response = true;
            break;
        }
    }
    assert!(saw_stale_backend_response);
    memory.reset();
    println!("MEMBACKENDTRACE|v2|case=reset_pending_masked|status=isolated");
    println!("PASS memory controller backend masked-write semantics");
}
