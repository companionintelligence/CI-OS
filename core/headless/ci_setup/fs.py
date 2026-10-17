"""A tiny read-only view of the file system, so code that looks at /sys or /proc can be tested without them.

``RealFs`` reads the real thing (and never raises: a missing or unreadable file is ``None``); ``DictFs`` serves a
dictionary. Neither can write, delete or rename anything.
"""
from __future__ import annotations

import os
from typing import Dict, Iterable, List, Optional


class RealFs:
    """Read-only access to the real file system."""

    def read_text(self, path: str, limit: int = 65536) -> Optional[str]:
        try:
            with open(path, "rb") as fh:
                return fh.read(limit).decode("utf-8", "replace")
        except OSError:
            return None

    def readlink(self, path: str) -> Optional[str]:
        try:
            return os.readlink(path)
        except OSError:
            return None

    def listdir(self, path: str) -> List[str]:
        try:
            return sorted(os.listdir(path))
        except OSError:
            return []

    def exists(self, path: str) -> bool:
        return os.path.exists(path)


class DictFs:
    """An in-memory stand-in: ``files`` maps absolute paths to text, ``links`` maps symlink paths to their target."""

    def __init__(self, files: Optional[Dict[str, str]] = None, links: Optional[Dict[str, str]] = None,
                 dirs: Optional[Iterable[str]] = None) -> None:
        self.files = dict(files or {})
        self.links = dict(links or {})
        self.extra_dirs = set(dirs or [])

    def read_text(self, path: str, limit: int = 65536) -> Optional[str]:
        text = self.files.get(path)
        return None if text is None else text[:limit]

    def readlink(self, path: str) -> Optional[str]:
        return self.links.get(path)

    def listdir(self, path: str) -> List[str]:
        prefix = path.rstrip("/") + "/"
        names = set()
        for p in list(self.files) + list(self.links) + list(self.extra_dirs):
            if p.startswith(prefix):
                names.add(p[len(prefix):].split("/", 1)[0])
        return sorted(names)

    def exists(self, path: str) -> bool:
        if path in self.files or path in self.links or path in self.extra_dirs:
            return True
        prefix = path.rstrip("/") + "/"
        return any(p.startswith(prefix) for p in list(self.files) + list(self.links) + list(self.extra_dirs))
