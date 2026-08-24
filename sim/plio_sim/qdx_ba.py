from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum

from .qdx import decode_u16, decode_u32, encode_u16, encode_u32


class BlockAccelOpcode(IntEnum):
    READ_OR = 0x20
    WRITE_OR = 0x21
    MULTI_WRITE = 0x22
    COPY = 0x23


BA_PARAMETER_VERSION = 1
BA_MAX_TARGETS = 16
BA_PARAMETER_HEADER_SIZE = 16
BA_TARGET_ENTRY_SIZE = 8
BA_RESULT_ENTRY_SIZE = 8

BA_STATUS_PARTIAL_SUCCESS = 0x0100
BA_STATUS_NO_TARGET_SUCCEEDED = 0x0101
BA_TARGET_NOT_ATTEMPTED = 0xFFFF

BA_RESULT_ATTEMPTED = 1 << 0
BA_RESULT_SELECTED = 1 << 1


@dataclass(frozen=True)
class BATarget:
    namespace_id: int
    lba: int
    flags: int = 0


@dataclass(frozen=True)
class BAParameterBlock:
    results_addr: int
    targets: tuple[BATarget, ...]
    flags: int = 0
    version: int = BA_PARAMETER_VERSION


@dataclass(frozen=True)
class BATargetResult:
    status: int
    flags: int
    blocks_done: int


def _validate_target(target: BATarget) -> None:
    if not 1 <= target.namespace_id <= 0xFFFF:
        raise ValueError("QDX-BA target namespace must be 1..65535")
    if not 0 <= target.flags <= 0xFFFF:
        raise ValueError("QDX-BA target flags outside 16-bit range")
    if target.flags != 0:
        raise ValueError("QDX-BA v0.2 target flags must be zero")
    if not 0 <= target.lba <= 0xFFFFFFFF:
        raise ValueError("QDX-BA target LBA outside 32-bit range")


def pack_parameter_block(block: BAParameterBlock) -> bytes:
    if block.version != BA_PARAMETER_VERSION:
        raise ValueError("QDX-BA parameter version must be 1")
    if not 1 <= len(block.targets) <= BA_MAX_TARGETS:
        raise ValueError("QDX-BA target count must be 1..16")
    if block.flags != 0:
        raise ValueError("QDX-BA v0.2 parameter flags must be zero")
    if not 0 <= block.results_addr <= 0xFFFFFFFF:
        raise ValueError("QDX-BA results address outside 32-bit range")

    payload = bytearray()
    payload += encode_u16(block.version)
    payload += encode_u16(len(block.targets))
    payload += encode_u32(block.flags)
    payload += encode_u32(block.results_addr)
    payload += encode_u32(0)

    for target in block.targets:
        _validate_target(target)
        payload += encode_u16(target.namespace_id)
        payload += encode_u16(target.flags)
        payload += encode_u32(target.lba)

    expected = BA_PARAMETER_HEADER_SIZE + BA_TARGET_ENTRY_SIZE * len(block.targets)
    if len(payload) != expected:
        raise AssertionError("internal QDX-BA parameter packing size mismatch")
    return bytes(payload)


def unpack_parameter_block(data: bytes) -> BAParameterBlock:
    if len(data) < BA_PARAMETER_HEADER_SIZE:
        raise ValueError("QDX-BA parameter block shorter than 16-byte header")

    version = decode_u16(data[0:2])
    target_count = decode_u16(data[2:4])
    flags = decode_u32(data[4:8])
    results_addr = decode_u32(data[8:12])
    reserved = decode_u32(data[12:16])

    if version != BA_PARAMETER_VERSION:
        raise ValueError("unsupported QDX-BA parameter version")
    if not 1 <= target_count <= BA_MAX_TARGETS:
        raise ValueError("QDX-BA target count must be 1..16")
    if flags != 0 or reserved != 0:
        raise ValueError("QDX-BA v0.2 flags/reserved fields must be zero")

    expected = BA_PARAMETER_HEADER_SIZE + BA_TARGET_ENTRY_SIZE * target_count
    if len(data) != expected:
        raise ValueError("QDX-BA parameter block length does not match target count")

    targets: list[BATarget] = []
    cursor = BA_PARAMETER_HEADER_SIZE
    for _ in range(target_count):
        target = BATarget(
            namespace_id=decode_u16(data[cursor : cursor + 2]),
            flags=decode_u16(data[cursor + 2 : cursor + 4]),
            lba=decode_u32(data[cursor + 4 : cursor + 8]),
        )
        _validate_target(target)
        targets.append(target)
        cursor += BA_TARGET_ENTRY_SIZE

    return BAParameterBlock(
        version=version,
        flags=flags,
        results_addr=results_addr,
        targets=tuple(targets),
    )


def pack_target_results(results: tuple[BATargetResult, ...] | list[BATargetResult]) -> bytes:
    if not 1 <= len(results) <= BA_MAX_TARGETS:
        raise ValueError("QDX-BA result count must be 1..16")

    payload = bytearray()
    for result in results:
        if not 0 <= result.status <= 0xFFFF:
            raise ValueError("QDX-BA target status outside 16-bit range")
        if not 0 <= result.flags <= 0xFFFF:
            raise ValueError("QDX-BA result flags outside 16-bit range")
        if result.flags & ~(BA_RESULT_ATTEMPTED | BA_RESULT_SELECTED):
            raise ValueError("QDX-BA v0.2 result contains reserved flag bits")
        if not 0 <= result.blocks_done <= 0xFFFFFFFF:
            raise ValueError("QDX-BA blocks_done outside 32-bit range")
        payload += encode_u16(result.status)
        payload += encode_u16(result.flags)
        payload += encode_u32(result.blocks_done)

    return bytes(payload)


def unpack_target_results(data: bytes) -> tuple[BATargetResult, ...]:
    if len(data) == 0 or len(data) % BA_RESULT_ENTRY_SIZE:
        raise ValueError("QDX-BA result array must contain whole 8-byte entries")
    count = len(data) // BA_RESULT_ENTRY_SIZE
    if count > BA_MAX_TARGETS:
        raise ValueError("QDX-BA result array exceeds 16 entries")

    results: list[BATargetResult] = []
    for cursor in range(0, len(data), BA_RESULT_ENTRY_SIZE):
        result = BATargetResult(
            status=decode_u16(data[cursor : cursor + 2]),
            flags=decode_u16(data[cursor + 2 : cursor + 4]),
            blocks_done=decode_u32(data[cursor + 4 : cursor + 8]),
        )
        if result.flags & ~(BA_RESULT_ATTEMPTED | BA_RESULT_SELECTED):
            raise ValueError("QDX-BA v0.2 result contains reserved flag bits")
        results.append(result)
    return tuple(results)
