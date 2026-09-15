use plio_host_model::{WorkerError, WorkerMmioEngine, WorkerRequest, WorkerResult, WorkerWidth};
use plio_logical_model::{odd_parity_32, CardToBus, PLIO_TIMEOUT_CYCLES};

fn ack() -> CardToBus { CardToBus { ack: true, ..CardToBus::default() } }

fn finish(engine: &mut WorkerMmioEngine) -> Result<WorkerResult, WorkerError> {
    engine.take_completion().expect("scenario must complete")
}

fn main() {
    let mut host = WorkerMmioEngine::new();

    host.start(WorkerRequest::read(2, 0x100, WorkerWidth::U32).unwrap()).unwrap();
    host.clock(false, ack());
    let data = 0xdead_beef;
    host.clock(false, CardToBus { ack: true, ad: Some(data), par: Some(odd_parity_32(data)), ..CardToBus::default() });
    assert_eq!(finish(&mut host), Ok(WorkerResult::Read(data)));
    println!("PLIOHOSTTRACE|v1|case=read32|status=ok|slot=2|value=deadbeef");

    host.start(WorkerRequest::write(1, 0x102, WorkerWidth::U16, 0xbeef).unwrap()).unwrap();
    host.clock(false, ack());
    assert_eq!(host.drive(false).bus.ad, Some(0xbeef_0000));
    host.clock(false, ack());
    assert_eq!(finish(&mut host), Ok(WorkerResult::WriteOk));
    println!("PLIOHOSTTRACE|v1|case=write16|status=ok|slot=1|bus=beef0000");

    host.start(WorkerRequest::read(0, 0x101, WorkerWidth::U8).unwrap()).unwrap();
    for _ in 0..2 { host.clock(false, CardToBus::default()); }
    host.clock(false, ack());
    for _ in 0..2 { host.clock(false, CardToBus::default()); }
    let lane = 0x1234_5a78;
    host.clock(false, CardToBus { ack: true, ad: Some(lane), par: Some(odd_parity_32(lane)), ..CardToBus::default() });
    assert_eq!(finish(&mut host), Ok(WorkerResult::Read(0x5a)));
    println!("PLIOHOSTTRACE|v1|case=wait_read8|status=ok|addr_wait=2|data_wait=2|value=5a");

    host.start(WorkerRequest::read(0, 0x100, WorkerWidth::U32).unwrap()).unwrap();
    host.clock(false, CardToBus { err: true, ..CardToBus::default() });
    assert_eq!(finish(&mut host), Err(WorkerError::BusError));
    println!("PLIOHOSTTRACE|v1|case=address_err|status=bus_error");

    host.start(WorkerRequest::write(0, 0x100, WorkerWidth::U32, 0x1122_3344).unwrap()).unwrap();
    host.clock(false, ack());
    host.clock(false, CardToBus { err: true, ..CardToBus::default() });
    assert_eq!(finish(&mut host), Err(WorkerError::BusError));
    println!("PLIOHOSTTRACE|v1|case=data_err|status=bus_error");

    host.start(WorkerRequest::read(0, 0x101, WorkerWidth::U8).unwrap()).unwrap();
    host.clock(false, ack());
    let bad = 0x0000_5a00;
    host.clock(false, CardToBus { ack: true, ad: Some(bad), par: Some(odd_parity_32(bad) ^ 0b0010), ..CardToBus::default() });
    assert_eq!(finish(&mut host), Err(WorkerError::ReadParity));
    println!("PLIOHOSTTRACE|v1|case=bad_parity|status=parity_error");

    host.start(WorkerRequest::read(0, 0x100, WorkerWidth::U32).unwrap()).unwrap();
    for _ in 0..PLIO_TIMEOUT_CYCLES { host.clock(false, CardToBus::default()); }
    assert_eq!(finish(&mut host), Err(WorkerError::Timeout));
    println!("PLIOHOSTTRACE|v1|case=timeout|phase=address|cycles=256");

    host.start(WorkerRequest::read(0, 0x100, WorkerWidth::U32).unwrap()).unwrap();
    host.clock(true, CardToBus::default());
    assert_eq!(finish(&mut host), Err(WorkerError::Reset));
    println!("PLIOHOSTTRACE|v1|case=reset_address|status=reset");

    host.start(WorkerRequest::read(0, 0x100, WorkerWidth::U32).unwrap()).unwrap();
    host.clock(false, ack());
    host.clock(true, CardToBus::default());
    assert_eq!(finish(&mut host), Err(WorkerError::Reset));
    println!("PLIOHOSTTRACE|v1|case=reset_data|status=reset");
}
