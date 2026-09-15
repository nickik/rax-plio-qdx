use plio_host_manager_model::{
    make_notification_address, make_notification_data, ManagerFault, ManagerState,
    NotificationConfig, NotificationClaim, PlioManagerM2, PLIO_SLOT_COUNT,
};
use plio_logical_model::{odd_parity_32, CardToBus, PLIO_TIMEOUT_CYCLES};

fn empty_cards() -> [CardToBus; PLIO_SLOT_COUNT] {
    [CardToBus::default(); PLIO_SLOT_COUNT]
}

fn grant(manager: &mut PlioManagerM2, slot: usize, held: &[usize]) -> [CardToBus; PLIO_SLOT_COUNT] {
    let mut cards = empty_cards();
    for s in held { cards[*s].request = true; }
    cards[slot].request = true;
    manager.clock(false, &cards, true);
    assert_eq!(manager.state(), ManagerState::Grant { slot: slot as u8 });
    cards
}

fn complete_notification(manager: &mut PlioManagerM2, slot: usize, channel: u8, payload: u32) {
    let mut cards = grant(manager, slot, &[]);
    cards[slot] = make_notification_address(true, channel);
    assert!(manager.drive(false, &cards, true).buses[slot].ack);
    manager.clock(false, &cards, true);
    cards[slot] = make_notification_data(true, payload);
    assert!(manager.drive(false, &cards, true).buses[slot].ack);
    manager.clock(false, &cards, true);
}

fn main() {
    let mut manager = PlioManagerM2::new();

    let mut cards = empty_cards();
    cards[2].request = true;
    cards[5].request = true;
    cards[7].request = true;
    manager.clock(false, &cards, true);
    assert_eq!(manager.drive(false, &cards, true).granted_slot, Some(2));
    cards[2] = make_notification_address(true, 0);
    manager.clock(false, &cards, true);
    cards[2] = make_notification_data(true, 0x22);
    manager.clock(false, &cards, true);
    manager.clock(false, &cards, true);
    assert_eq!(manager.drive(false, &cards, true).granted_slot, Some(5));
    cards[5] = make_notification_address(true, 0);
    manager.clock(false, &cards, true);
    cards[5] = make_notification_data(true, 0x55);
    manager.clock(false, &cards, true);
    manager.clock(false, &cards, true);
    assert_eq!(manager.drive(false, &cards, true).granted_slot, Some(7));
    println!("PLIOHOSTM2TRACE|v1|case=round_robin|grants=2,5,7|one_hot=1");

    let mut manager = PlioManagerM2::new();
    complete_notification(&mut manager, 3, 0, 0x31);
    let mut cards = empty_cards();
    cards[3].request = true;
    manager.clock(false, &cards, true);
    assert_eq!(manager.grant_count(3), 2);
    println!("PLIOHOSTM2TRACE|v1|case=repeated|slot=3|grants=2");

    let mut manager = PlioManagerM2::new();
    let mut cards = grant(&mut manager, 1, &[]);
    cards[1] = make_notification_address(true, 2);
    manager.clock(false, &cards, true);
    cards[1] = make_notification_data(true, 0xfeed_beef);
    for _ in 0..3 {
        assert!(!manager.drive(false, &cards, false).buses[1].ack);
        manager.clock(false, &cards, false);
    }
    assert_eq!(manager.debug().wait_cycles, 3);
    manager.clock(false, &cards, true);
    assert_eq!(manager.notification_payload(1, 2), 0xfeed_beef);
    println!("PLIOHOSTM2TRACE|v1|case=backpressure|slot=1|channel=2|wait=3|payload=feedbeef");

    let mut manager = PlioManagerM2::new();
    let mut cards = grant(&mut manager, 0, &[]);
    cards[0] = make_notification_address(true, 0);
    cards[0].par = Some(cards[0].par.unwrap() ^ 1);
    assert!(manager.drive(false, &cards, true).buses[0].err);
    manager.clock(false, &cards, true);
    assert_eq!(manager.last_fault(), Some(ManagerFault::AddressParity));
    println!("PLIOHOSTM2TRACE|v1|case=address_parity|status=error");

    let mut manager = PlioManagerM2::new();
    let mut cards = grant(&mut manager, 0, &[]);
    cards[0] = make_notification_address(true, 1);
    manager.clock(false, &cards, true);
    cards[0] = make_notification_data(true, 0x1234_5678);
    cards[0].par = Some(odd_parity_32(0x1234_5678) ^ 1);
    assert!(manager.drive(false, &cards, true).buses[0].err);
    manager.clock(false, &cards, true);
    assert_eq!(manager.last_fault(), Some(ManagerFault::DataParity));
    println!("PLIOHOSTM2TRACE|v1|case=data_parity|status=error");

    let mut manager = PlioManagerM2::new();
    let cards = grant(&mut manager, 6, &[]);
    for _ in 0..PLIO_TIMEOUT_CYCLES { manager.clock(false, &cards, true); }
    assert_eq!(manager.last_fault(), Some(ManagerFault::Timeout));
    println!("PLIOHOSTM2TRACE|v1|case=timeout|phase=grant|cycles=256");

    let mut manager = PlioManagerM2::new();
    complete_notification(&mut manager, 2, 1, 0xaa55_aa55);
    let cards = grant(&mut manager, 5, &[]);
    let drive = manager.drive(true, &cards, true);
    assert_eq!(drive.granted_slot, None);
    manager.clock(true, &cards, true);
    assert!(!manager.notification_pending(2, 1));
    assert_eq!(manager.cursor(), 0);
    println!("PLIOHOSTM2TRACE|v1|case=reset|grant=withdrawn|pending=cleared|cursor=0");

    let mut manager = PlioManagerM2::new();
    complete_notification(&mut manager, 4, 0, 0x40);
    complete_notification(&mut manager, 1, 3, 0x13);
    complete_notification(&mut manager, 1, 1, 0x11);
    manager.set_notification_config(1, 1, NotificationConfig { enabled: true, masked: true, class: 2 });
    manager.set_notification_config(1, 3, NotificationConfig { enabled: true, masked: false, class: 7 });
    manager.set_notification_config(4, 0, NotificationConfig { enabled: false, masked: false, class: 9 });
    assert_eq!(manager.peek_claim(), Some(NotificationClaim { slot: 1, channel: 3, payload: 0x13, class: 7 }));
    let first = manager.claim().unwrap();
    manager.set_notification_config(1, 1, NotificationConfig { enabled: true, masked: false, class: 2 });
    let second = manager.claim().unwrap();
    assert_eq!((first.slot, first.channel, first.class), (1, 3, 7));
    assert_eq!((second.slot, second.channel, second.class), (1, 1, 2));
    assert!(manager.claim().is_none());
    println!("PLIOHOSTM2TRACE|v1|case=claim_order|first=1:3:7|second=1:1:2|disabled_4:0=held");
}
