"""Clocks.

All elapsed-time code in this package takes a clock object with a ``now()`` method that returns seconds as a float.
It is a *monotonic* reading, never wall-clock time: a device without a real-time clock can jump by years when NTP
first syncs, and a token or lockout must not expire or extend because of that. Only the difference between two
readings of the same clock means anything.

There is one legitimate use of wall time, and it has its own pair of classes (``WallClock``, ``ManualWallClock``) so that it cannot
be mistaken for the above: an *absolute* expiry that somebody else chose. A signed statement says "valid until 1767225600"; no
monotonic reading can say whether that moment has come. The code that takes a wall clock (statement.py, with replay.py) assumes
the reading can be wrong and fails closed: it refuses an expiry that is too far ahead of the reading, and it remembers the latest
time at which it accepted anything so that a clock that went backwards is noticed. Everything that measures how long something
took stays monotonic.
"""
from __future__ import annotations

import time


class SystemClock:
    """The real monotonic clock."""

    def now(self) -> float:
        return time.monotonic()


class ManualClock:
    """A clock that only moves when told to; for tests and the selftest."""

    def __init__(self, start: float = 1000.0) -> None:
        self._t = float(start)

    def now(self) -> float:
        return self._t

    def advance(self, seconds: float) -> float:
        if seconds < 0:
            raise ValueError("a clock cannot go backwards")
        self._t += float(seconds)
        return self._t


class WallClock:
    """The real wall clock: whole seconds since the epoch (UTC) from ``time.time()``. For an absolute expiry that a signer chose
    and for nothing else (see the module text). It can jump in either direction, and the code that uses it is written for that."""

    def now(self) -> int:
        return int(time.time())


class ManualWallClock:
    """A wall clock that only moves when told to; for tests and the selftest. Unlike :class:`ManualClock` it may go BACKWARDS, on
    purpose: that is how a test models a real-time clock that was reset or a snapshot that was restored. Times are whole seconds."""

    def __init__(self, start: int = 1_700_000_000) -> None:
        self._t = _whole(start)

    def now(self) -> int:
        return self._t

    def set(self, seconds: int) -> int:
        """Jump to ``seconds``, forwards or backwards."""
        self._t = _whole(seconds)
        return self._t

    def advance(self, seconds: int) -> int:
        """Move by ``seconds``; a negative number moves backwards."""
        self._t += _whole(seconds)
        return self._t


def _whole(seconds: int) -> int:
    if type(seconds) is not int:
        raise TypeError("a wall clock holds whole seconds (an int)")
    return seconds
