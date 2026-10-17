"""Writing a file that holds a secret (the hostapd configuration, a PIN file): created with mode 0600 from the first byte.

The old service created its files with ``open()`` and ``chmod`` afterwards, which leaves a window in which the file is
readable by everyone, and wrote the hostapd configuration (with the AP key) mode 0644. Here the file is created by
``os.open(..., O_CREAT | O_EXCL, 0o600)`` under a temporary name next to the target, filled, synced, and renamed over the
target, so the secret is never in a readable file and a reader never sees a half-written one. The umask can only narrow the
mode, never widen it.
"""
from __future__ import annotations

import os
import secrets
from typing import Union

_FLAGS = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)


def write_private_file(path: str, data: Union[str, bytes], mode: int = 0o600) -> None:
    """Atomically create or replace ``path`` with ``data``, mode ``mode`` (default 0600). ``path`` must be absolute."""
    if not isinstance(path, str) or not os.path.isabs(path) or "\x00" in path:
        raise ValueError("an absolute path is required")
    if mode & 0o177:
        raise ValueError("a private file has no group or other permissions")
    payload = data.encode("utf-8") if isinstance(data, str) else bytes(data)
    tmp = "%s.tmp-%s" % (path, secrets.token_hex(6))
    fd = os.open(tmp, _FLAGS, mode)
    try:
        try:
            os.fchmod(fd, mode)
        except (AttributeError, OSError):
            pass
        view = memoryview(payload)
        while view:
            n = os.write(fd, view)
            view = view[n:]
        os.fsync(fd)
    except BaseException:
        os.close(fd)
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    os.close(fd)
    try:
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
