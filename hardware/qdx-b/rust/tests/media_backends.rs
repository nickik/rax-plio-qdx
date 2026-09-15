use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

use qdx_b_model::{BlockBackend, FakeMedia, FileDisk, RamDisk, NS_BLOCKS};

fn unique_path(name: &str) -> std::path::PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("qdx-b-{name}-{}-{nonce}.img", std::process::id()))
}

#[test]
fn ram_disk_backend_round_trips_one_block() {
    let mut disk = RamDisk::new(NS_BLOCKS, 512).unwrap();
    let src: Vec<u32> = (0..128).map(|i| 0x1234_0000 + i).collect();
    let mut dst = vec![0u32; 128];

    disk.write_block(7, &src).unwrap();
    disk.read_block(7, &mut dst).unwrap();

    assert_eq!(dst, src);
    assert_eq!(disk.block_size(), 512);
    assert_eq!(disk.total_blocks(), NS_BLOCKS);
}

#[test]
fn file_disk_persists_after_flush_and_reopen() {
    let path = unique_path("persistent");
    let src: Vec<u32> = (0..128).map(|i| 0xa500_0000 + i * 4).collect();

    {
        let mut disk = FileDisk::create(&path, NS_BLOCKS, 512).unwrap();
        disk.write_block(3, &src).unwrap();
        disk.flush().unwrap();
    }

    {
        let mut disk = FileDisk::open(&path, 512, true).unwrap();
        let mut dst = vec![0u32; 128];
        disk.read_block(3, &mut dst).unwrap();
        assert_eq!(dst, src);
        assert!(disk.read_only());
    }

    fs::remove_file(path).unwrap();
}

#[test]
fn fake_media_can_use_two_file_backed_external_disks() {
    let path512 = unique_path("ns512");
    let path1024 = unique_path("ns1024");
    let pattern: [u32; 256] = std::array::from_fn(|i| 0x5a00_0000 + i as u32);

    {
        let mut media = FakeMedia::file_backed(&path512, &path1024).unwrap();
        assert!(media.write_block(1, 5, &pattern));
        assert!(media.write_block(2, 6, &pattern));
        media.flush(1);
        media.flush(2);
        assert_eq!(media.flushes, 2);
    }

    {
        let mut disk512 = FileDisk::open(&path512, 512, true).unwrap();
        let mut dst512 = vec![0u32; 128];
        disk512.read_block(5, &mut dst512).unwrap();
        assert_eq!(dst512, pattern[..128]);

        let mut disk1024 = FileDisk::open(&path1024, 1024, true).unwrap();
        let mut dst1024 = vec![0u32; 256];
        disk1024.read_block(6, &mut dst1024).unwrap();
        assert_eq!(dst1024, pattern);
    }

    fs::remove_file(path512).unwrap();
    fs::remove_file(path1024).unwrap();
}
