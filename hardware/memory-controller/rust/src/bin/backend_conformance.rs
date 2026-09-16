use memory_controller_model::{ControllerState, FakeMemory, MemoryBackend, MemoryController};
use plio_host_dma_model::{MemoryRequest, MemoryResponse};

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
            MemoryRequest::Write32 { physical_address: 0x100, value: 0x1111_1111 },
        ),
        MemoryResponse::WriteDone
    );
    assert_eq!(
        transact(
            &mut controller,
            &mut memory,
            MemoryRequest::Write32 { physical_address: 0x104, value: 0x2222_2222 },
        ),
        MemoryResponse::WriteDone
    );
    assert_eq!(memory.peek_word(0x100), Some(0x1111_1111));
    assert_eq!(memory.peek_word(0x104), Some(0x2222_2222));
    assert_eq!(
        transact(
            &mut controller,
            &mut memory,
            MemoryRequest::Read32 { physical_address: 0x100 },
        ),
        MemoryResponse::ReadData(0x1111_1111)
    );
    assert_eq!(
        transact(
            &mut controller,
            &mut memory,
            MemoryRequest::Read32 { physical_address: 0x104 },
        ),
        MemoryResponse::ReadData(0x2222_2222)
    );
    println!("MEMBACKENDTRACE|v1|case=raw_multi_address|status=ok|a=11111111|b=22222222");

    assert!(controller.accept_host_request(MemoryRequest::Read32 { physical_address: 0x100 }));
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
            MemoryRequest::Read32 { physical_address: 0x100 },
        ),
        MemoryResponse::ReadData(0x1111_1111)
    );
    println!("MEMBACKENDTRACE|v1|case=reset_recovery|status=ok|value=11111111");
    println!("PASS memory controller backend sequence semantics");
}
