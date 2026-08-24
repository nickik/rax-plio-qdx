from __future__ import annotations

RAX_PLIO_MMIO_BASE = 0xF000_0000
RAX_PLIO_MMIO_END = 0xFFFF_FFFF
RAX_PLIO_SLOT_COUNT = 8
RAX_PLIO_SLOT_WINDOW = 32 * 1024 * 1024
RAX_PLIO_HOST_CSR_BASE = 0xEFFF_F000
RAX_PLIO_HOST_CSR_END = 0xEFFF_FFFF


def decode_plio_mmio(address: int) -> tuple[int, int]:
    if not RAX_PLIO_MMIO_BASE <= address <= RAX_PLIO_MMIO_END:
        raise ValueError("address outside RAX PLIO MMIO region")
    relative = address - RAX_PLIO_MMIO_BASE
    slot = relative // RAX_PLIO_SLOT_WINDOW
    offset = relative % RAX_PLIO_SLOT_WINDOW
    if not 0 <= slot < RAX_PLIO_SLOT_COUNT:
        raise ValueError("invalid decoded PLIO slot")
    return slot, offset


def encode_plio_mmio(slot: int, offset: int) -> int:
    if not 0 <= slot < RAX_PLIO_SLOT_COUNT:
        raise ValueError("PLIO slot must be 0..7")
    if not 0 <= offset < RAX_PLIO_SLOT_WINDOW:
        raise ValueError("PLIO slot offset outside 32 MiB window")
    return RAX_PLIO_MMIO_BASE + slot * RAX_PLIO_SLOT_WINDOW + offset
