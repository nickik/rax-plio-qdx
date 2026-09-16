use memory_controller_model::{masked_write, ControllerState, FakeMemory, MemoryBackend, MemoryController, MemoryRequest};
use plio_host_dma_model::MemoryResponse;

fn transact(controller: &mut MemoryController, memory: &mut FakeMemory, request: MemoryRequest) -> MemoryResponse {
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

    for mask in 0_u8..16 {
        let address = 0x200 + u32::from(mask) * 4;
        assert!(memory.preload_word(address, 0x1122_3344));
        assert_eq!(
            transact(&mut controller, &mut memory, MemoryRequest::write(address, mask, 0xaabb_ccdd)),
            MemoryResponse::WriteDone
        );
        let expected = masked_write(0x1122_3344, 0xaabb_ccdd, mask);
        assert_eq!(memory.peek_word(address), Some(expected));
        // Deliberately vary the read BE: it is retained by the request but must
        // never mask the returned 32-bit word.
        assert_eq!(
            transact(&mut controller, &mut memory, MemoryRequest::read(address, (!mask) & 0x0f)),
            MemoryResponse::ReadData(expected)
        );
        println!("MEMSEMTRACE|v1|mask={mask:x}|value={expected:08x}|read=full");
    }

    let fault_request = MemoryRequest::write(0x1000, 0x5, 0xcafe_babe);
    assert!(controller.accept_host_request(fault_request));
    assert_eq!(controller.backend_request(), Some(fault_request));
    for _ in 0..128 {
        controller.tick_backend(&mut memory);
        if controller.host_response().is_some() { break; }
    }
    assert_eq!(controller.host_response(), Some(MemoryResponse::Fault));
    assert!(controller.consume_host_response());
    println!("MEMSEMTRACE|v1|fault|be=5|status=propagated");

    let reset_request = MemoryRequest::write(0x300, 0x9, 0xcafe_babe);
    assert!(controller.accept_host_request(reset_request));
    while controller.debug().state != ControllerState::BackendResponse {
        controller.tick_backend(&mut memory);
    }
    assert_eq!(memory.response(), None);
    controller.reset();

    let mut saw_stale = false;
    for _ in 0..128 {
        controller.tick_backend(&mut memory);
        assert_eq!(controller.debug().state, ControllerState::Idle);
        assert!(controller.host_request_ready());
        assert_eq!(controller.host_response(), None);
        if memory.response().is_some() {
            saw_stale = true;
            break;
        }
    }
    assert!(saw_stale, "backend never produced the intentionally stale completion");
    assert_eq!(controller.host_response(), None);
    memory.reset();
    println!("MEMSEMTRACE|v1|reset|be=9|stale=isolated");
    println!("PASS exhaustive memory controller byte-enable semantics");
}
