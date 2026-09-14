use pti_model::*;

fn dump(name: &str, tokens: &[Token]) {
    print!("VECTOR {name}");
    for t in tokens {
        print!(" {:01x}:{:05x}", t.kind as u8, t.ptd);
    }
    println!();
}

fn main() {
    dump("PTI_DATA", &encode_data_beat(0x89ab_cdef, 0b1010).unwrap());
    dump("PTI_DATA_ZERO", &encode_data_beat(0, 0).unwrap());
    let control = ControlImage {
        space: 2,
        address_strobe: true,
        read: true,
        byte_enable: 0xf,
        burst_len: 3,
        data_strobe: true,
        drive_ad_par: true,
        drive_control: false,
    };
    dump("PTI_CONTROL", &[encode_control(control).unwrap()]);
}
