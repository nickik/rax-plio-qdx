from __future__ import annotations


class HostMemory:
    """Byte-addressable host physical memory used by the functional model."""

    def __init__(self, size: int):
        if size <= 0:
            raise ValueError("memory size must be positive")
        self._data = bytearray(size)

    @property
    def size(self) -> int:
        return len(self._data)

    def _bounds(self, address: int, length: int) -> slice:
        if address < 0 or length < 0 or address + length > self.size:
            raise IndexError(f"host memory access outside range: 0x{address:x}+{length}")
        return slice(address, address + length)

    def read(self, address: int, length: int) -> bytes:
        return bytes(self._data[self._bounds(address, length)])

    def write(self, address: int, data: bytes | bytearray | memoryview) -> None:
        payload = bytes(data)
        self._data[self._bounds(address, len(payload))] = payload
