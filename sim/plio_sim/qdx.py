from __future__ import annotations

from collections import deque
from typing import Generic, TypeVar

T = TypeVar("T")


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
