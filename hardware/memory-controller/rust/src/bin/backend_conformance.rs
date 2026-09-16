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

    assert_eq!(
        transact(
            &mut controller,
            &mut memory,
            MemoryRequest::write(0x100, 0xf, 0x1111_1111),
        ),
        MemoryResponse::WriteDone
    );
    assert_eq!(
        transact(
            &mut controller,
            &mut memory,
            MemoryRequest::write(0x104, 0xf, 0x2222_2222),
        ),
        MemoryResponse::WriteDone
    );
    assert_eq!(memory.peek_word(0x100), Some(0x1111_1111));
    assert_eq!(memory.peek_word(0x104), Some(0x2222_2222));
    assert_eq!(
        transact(
            &mut controller,
            &mut memory,
            MemoryRequest::read(0x100, 0xf),
        ),
        MemoryResponse::ReadData(0x1111_1111)
    );
    assert_eq!(
        transact(
            &mut controller,
            &mut memory,
            MemoryRequest::read(0x104, 0xf),
        ),
        MemoryResponse::ReadData(0x2222_2222)
    );
    println!("MEMBACKENDTRACE|v1|case=raw_multi_address|status=ok|a=11111111|b=22222222");

    // Exercise the shared backend's masked-write semantics in the conformance
    // executable as well as the unit tests. BE=0101 updates lanes 0 and 2.
    assert_eq!(
        transact(
            &mut controller,
            &mut memory,
            MemoryRequest::write(0x100, 0x5, 0xaabb_ccdd),
        ),
        MemoryResponse::WriteDone
    );
    assert_eq!(memory.peek_word(0x100), Some(0x11bb_11dd));
    println!("MEMBACKENDTRACE|v2|case=masked_write|be=5|value=11bb11dd|status=ok");

    assert!(controller.accept_host_request(MemoryRequest::read(0x100, 0xf)));
    controller.tick_backend(&mut memory);
    assert_eq!(controller.debug().state, ControllerState::BackendResponse);
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
    println!("MEMBACKENDTRACE|v1|case=reset_pending|status=isolated");

    memory.reset();
    assert_eq!(memory.response(), None);
    assert_eq!(
        transact(
            &mut controller,
            &mut memory,
            MemoryRequest::read(0x100, 0xf),
        ),
        MemoryResponse::ReadData(0x11bb_11dd)
    );
    println!("MEMBACKENDTRACE|v2|case=reset_recovery|status=ok|value=11bb11dd");
    println!("PASS memory controller backend sequence semantics");
}
