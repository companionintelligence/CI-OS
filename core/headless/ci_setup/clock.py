"""Clocks.

All time-dependent code in this package takes a clock object with a ``now()`` method that returns seconds as a float.
It is a *monotonic* reading, never wall-clock time: a device without a real-time clock can jump by years when NTP
first syncs, and a token or lockout must not expire or extend because of that. Only the difference between two
readings of the same clock means anything.
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
