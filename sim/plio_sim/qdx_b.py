from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum

from .plio import DMAFault, PLIOController
from .qdx import CompletionQueue, SubmissionQueue


class BlockOpcode(IntEnum):
    NOP = 0x00
    IDENTIFY_CONTROLLER = 0x01
    IDENTIFY_NAMESPACE = 0x02
    READ = 0x10
    WRITE = 0x11
    FLUSH = 0x12
    GET_HEALTH = 0x13


class BlockStatus(IntEnum):
    SUCCESS = 0
    INVALID_OPCODE = 1
    INVALID_NAMESPACE = 2
    RANGE_ERROR = 3
    DMA_FAULT = 4


@dataclass(frozen=True)
class BlockCommand:
    opcode: BlockOpcode | int
    tag: int
    namespace: int
    lba: int = 0
    block_count: int = 0
    buffer_address: int = 0


@dataclass(frozen=True)
class BlockCompletion:
    tag: int
    status: BlockStatus
    bytes_transferred: int = 0


class Namespace:
    def __init__(self, blocks: int, block_size: int = 512):
        if blocks <= 0 or block_size <= 0:
            raise ValueError("namespace geometry must be positive")
        self.block_size = block_size
        self.blocks = blocks
        self._data = bytearray(blocks * block_size)

    def _range(self, lba: int, count: int) -> slice:
        if lba < 0 or count < 0 or lba + count > self.blocks:
            raise IndexError("namespace block range outside device")
        begin = lba * self.block_size
        return slice(begin, begin + count * self.block_size)

    def read(self, lba: int, count: int) -> bytes:
        return bytes(self._data[self._range(lba, count)])

    def write(self, lba: int, payload: bytes) -> None:
        if len(payload) % self.block_size:
            raise ValueError("payload must be whole blocks")
        count = len(payload) // self.block_size
        self._data[self._range(lba, count)] = payload


class BlockController:
    """QDX-B functional controller bound to one PLIO slot."""

    def __init__(
        self,
        plio: PLIOController,
        slot: int,
        *,
        queue_depth: int = 32,
        notification_channel: int = 0,
    ):
        self.plio = plio
        self.slot = slot
        self.notification_channel = notification_channel
        self.sq: SubmissionQueue[BlockCommand] = SubmissionQueue(queue_depth)
        self.cq: CompletionQueue[BlockCompletion] = CompletionQueue(queue_depth)
        self.namespaces: dict[int, Namespace] = {}

    def add_namespace(self, namespace_id: int, namespace: Namespace) -> None:
        if namespace_id <= 0:
            raise ValueError("namespace IDs begin at 1")
        self.namespaces[namespace_id] = namespace

    def submit(self, command: BlockCommand) -> None:
        self.sq.push(command)

    def _complete(self, completion: BlockCompletion) -> None:
        was_empty = self.cq.empty
        self.cq.push(completion)
        if was_empty:
            self.plio.notify(self.slot, self.notification_channel)

    def process_one(self) -> bool:
        if self.sq.empty:
            return False
        cmd = self.sq.pop()
        try:
            opcode = BlockOpcode(cmd.opcode)
        except ValueError:
            self._complete(BlockCompletion(cmd.tag, BlockStatus.INVALID_OPCODE))
            return True

        if opcode in (
            BlockOpcode.NOP,
            BlockOpcode.FLUSH,
            BlockOpcode.IDENTIFY_CONTROLLER,
            BlockOpcode.GET_HEALTH,
        ):
            self._complete(BlockCompletion(cmd.tag, BlockStatus.SUCCESS))
            return True

        namespace = self.namespaces.get(cmd.namespace)
        if namespace is None:
            self._complete(BlockCompletion(cmd.tag, BlockStatus.INVALID_NAMESPACE))
            return True

        if opcode == BlockOpcode.IDENTIFY_NAMESPACE:
            self._complete(BlockCompletion(cmd.tag, BlockStatus.SUCCESS))
            return True

        length = cmd.block_count * namespace.block_size
        try:
            if opcode == BlockOpcode.WRITE:
                payload = self.plio.dma_read(self.slot, cmd.buffer_address, length)
                namespace.write(cmd.lba, payload)
            elif opcode == BlockOpcode.READ:
                payload = namespace.read(cmd.lba, cmd.block_count)
                self.plio.dma_write(self.slot, cmd.buffer_address, payload)
            else:
                self._complete(BlockCompletion(cmd.tag, BlockStatus.INVALID_OPCODE))
                return True
        except DMAFault:
            self._complete(BlockCompletion(cmd.tag, BlockStatus.DMA_FAULT))
            return True
        except (IndexError, ValueError):
            self._complete(BlockCompletion(cmd.tag, BlockStatus.RANGE_ERROR))
            return True

        self._complete(BlockCompletion(cmd.tag, BlockStatus.SUCCESS, length))
        return True

    def reap(self) -> BlockCompletion:
        return self.cq.pop()
