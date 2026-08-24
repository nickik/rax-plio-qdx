from __future__ import annotations

from collections import deque
from typing import Generic, TypeVar

T = TypeVar("T")

QDX_BYTE_ORDER = "little"


def encode_u16(value: int) -> bytes:
    if not 0 <= value <= 0xFFFF:
        raise ValueError("value outside unsigned 16-bit range")
    return value.to_bytes(2, QDX_BYTE_ORDER)


def encode_u32(value: int) -> bytes:
    if not 0 <= value <= 0xFFFFFFFF:
        raise ValueError("value outside unsigned 32-bit range")
    return value.to_bytes(4, QDX_BYTE_ORDER)


def decode_u16(data: bytes) -> int:
    if len(data) != 2:
        raise ValueError("QDX u16 requires exactly 2 bytes")
    return int.from_bytes(data, QDX_BYTE_ORDER)


def decode_u32(data: bytes) -> int:
    if len(data) != 4:
        raise ValueError("QDX u32 requires exactly 4 bytes")
    return int.from_bytes(data, QDX_BYTE_ORDER)


class _Ring(Generic[T]):
    def __init__(self, depth: int):
        if depth <= 0:
            raise ValueError("queue depth must be positive")
        self.depth = depth
        self._items: deque[T] = deque()

    def __len__(self) -> int:
        return len(self._items)

    @property
    def empty(self) -> bool:
        return not self._items

    @property
    def full(self) -> bool:
        return len(self._items) >= self.depth

    def push(self, item: T) -> None:
        if self.full:
            raise BufferError("QDX queue full")
        self._items.append(item)

    def pop(self) -> T:
        if self.empty:
            raise BufferError("QDX queue empty")
        return self._items.popleft()


class SubmissionQueue(_Ring[T]):
    pass


class CompletionQueue(_Ring[T]):
    pass
