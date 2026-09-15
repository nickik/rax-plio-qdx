use plio_tx_model::{BackplaneControl, BackplaneSample, PlioTx, PtiDirection, QicPtiDrive};
use pti_model::{encode_control, encode_data_beat, ControlImage, Token, TokenKind};

fn pack_bus_control(c: BackplaneControl) -> u16 {
    u16::from(c.space)
        | ((c.address_strobe as u16) << 2)
        | ((c.read as u16) << 3)
        | (u16::from(c.byte_enable) << 4)
        | (u16::from(c.burst_len) << 8)
        | ((c.data_strobe as u16) << 10)
}

fn emit(slot: u8, tx: &mut PlioTx, reset: bool, qic: QicPtiDrive, bus: BackplaneSample) {
    let (bp, obs) = tx.step(reset, qic, bus);
    let (adv, ad, par) = bp.ad_par.map(|(a, p)| (1, a, p)).unwrap_or((0, 0, 0));
    let (cv, ctl) = bp.control.map(|c| (1, pack_bus_control(c))).unwrap_or((0, 0));
    let (rv, rack, rerr) = bp.response.map(|(a, e)| (1, a as u8, e as u8)).unwrap_or((0, 0, 0));
    let (rxv, rxk, rxp) = obs.rx_token
        .map(|t| (1, t.kind as u8, t.ptd))
        .unwrap_or((0, 0, 0));

    println!(
        "TXTRACE|v1|s={slot:02x}|bp={adv}.{ad:08x}.{par:01x}.{cv}.{ctl:04x}.{rv}.{rack}.{rerr}.{}|rx={rxv}.{rxk}.{rxp:05x}|st={}.{}.{}.{}.{}.{}",
        bp.request as u8,
        obs.sample_ack as u8,
        obs.sample_err as u8,
        obs.sample_selected as u8,
        obs.sample_grant as u8,
        obs.protocol_fault as u8,
        obs.contention as u8,
    );
}

fn qic_token(token: Token) -> QicPtiDrive {
    QicPtiDrive { token, ..QicPtiDrive::default() }
}

fn receive(kind: TokenKind) -> QicPtiDrive {
    QicPtiDrive {
        direction: PtiDirection::TxToQic,
        token: Token { kind, ptd: 0 },
        ..QicPtiDrive::default()
    }
}

fn idle(direction: PtiDirection) -> QicPtiDrive {
    QicPtiDrive {
        direction,
        token: Token { kind: TokenKind::Idle, ptd: 0 },
        ..QicPtiDrive::default()
    }
}

fn main() {
    let mut tx = PlioTx::new();
    let mut s = 0u8;

    emit(s, &mut tx, true, QicPtiDrive::default(), BackplaneSample::default()); s += 1;

    let control = ControlImage {
        space: 1,
        address_strobe: true,
        read: true,
        byte_enable: 0xf,
        burst_len: 2,
        data_strobe: false,
        drive_ad_par: true,
        drive_control: true,
    };
    let pair = encode_data_beat(0x89ab_cdef, 0b1010).unwrap();
    emit(s, &mut tx, false, qic_token(encode_control(control).unwrap()), BackplaneSample::default()); s += 1;
    emit(s, &mut tx, false, qic_token(pair[0]), BackplaneSample::default()); s += 1;
    emit(s, &mut tx, false, qic_token(pair[1]), BackplaneSample::default()); s += 1;
    emit(s, &mut tx, false, idle(PtiDirection::QicToTx), BackplaneSample::default()); s += 1;
    emit(s, &mut tx, false, QicPtiDrive { drive_enable: true, bus_request: true, ..Default::default() }, BackplaneSample::default()); s += 1;

    emit(s, &mut tx, false, QicPtiDrive {
        response_enable: true,
        response_ack: true,
        ..Default::default()
    }, BackplaneSample { ack: true, selected: true, grant: true, ..Default::default() }); s += 1;

    emit(s, &mut tx, false, idle(PtiDirection::TxToQic), BackplaneSample::default()); s += 1;
    let rc = BackplaneControl {
        space: 2,
        address_strobe: true,
        read: false,
        byte_enable: 0xc,
        burst_len: 3,
        data_strobe: true,
    };
    emit(s, &mut tx, false, receive(TokenKind::Control), BackplaneSample {
        control: rc,
        ack: true,
        selected: true,
        grant: true,
        ..Default::default()
    }); s += 1;

    emit(s, &mut tx, false, receive(TokenKind::DataLo), BackplaneSample {
        ad: 0x1122_3344,
        par: 0b1010,
        ..Default::default()
    }); s += 1;
    emit(s, &mut tx, false, receive(TokenKind::DataHi), BackplaneSample {
        ad: 0xaabb_ccdd,
        par: 0b0101,
        ..Default::default()
    }); s += 1;
    // HI without a new LO: no receive payload and sticky protocol fault.
    emit(s, &mut tx, false, receive(TokenKind::DataHi), BackplaneSample::default()); s += 1;

    emit(s, &mut tx, true, QicPtiDrive::default(), BackplaneSample::default()); s += 1;
    emit(s, &mut tx, false, qic_token(Token::new(TokenKind::DataHi, 0x1234, 2).unwrap()), BackplaneSample::default()); s += 1;

    emit(s, &mut tx, true, QicPtiDrive::default(), BackplaneSample::default()); s += 1;
    emit(s, &mut tx, false, qic_token(encode_control(ControlImage {
        drive_control: true,
        ..ControlImage::default()
    }).unwrap()), BackplaneSample::default()); s += 1;
    // No intervening idle: drive rise is suppressed and faulted.
    emit(s, &mut tx, false, QicPtiDrive { drive_enable: true, ..Default::default() }, BackplaneSample::default()); s += 1;

    emit(s, &mut tx, true, QicPtiDrive::default(), BackplaneSample::default()); s += 1;
    let data_only = ControlImage {
        byte_enable: 0xf,
        data_strobe: true,
        drive_ad_par: true,
        ..ControlImage::default()
    };
    let pair2 = encode_data_beat(0x0102_0304, 0xf).unwrap();
    emit(s, &mut tx, false, qic_token(encode_control(data_only).unwrap()), BackplaneSample::default()); s += 1;
    emit(s, &mut tx, false, qic_token(pair2[0]), BackplaneSample::default()); s += 1;
    emit(s, &mut tx, false, qic_token(pair2[1]), BackplaneSample::default()); s += 1;
    emit(s, &mut tx, false, idle(PtiDirection::QicToTx), BackplaneSample::default()); s += 1;
    emit(s, &mut tx, false, QicPtiDrive { drive_enable: true, ..Default::default() }, BackplaneSample {
        external_ad_par_drive: true,
        ..Default::default()
    }); s += 1;

    emit(s, &mut tx, true, QicPtiDrive::default(), BackplaneSample::default()); s += 1;
    // Illegal simultaneous response assertion must not drive the pair.
    emit(s, &mut tx, false, QicPtiDrive {
        response_enable: true,
        response_ack: true,
        response_err: true,
        ..Default::default()
    }, BackplaneSample::default());
}
