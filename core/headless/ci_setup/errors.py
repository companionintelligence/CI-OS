"""Exceptions shared by the ci_setup modules."""
from __future__ import annotations

from typing import Optional


class CiSetupError(Exception):
    """Base class for errors raised on purpose by this package."""


class ValidationError(ValueError, CiSetupError):
    """An input was rejected.

    ``field`` names what was being validated, ``code`` is a short stable machine-readable reason (``type``,
    ``empty``, ``length``, ``control_char``, ``charset``, ``format``, ``range``, ``encoding``, ``json`` ...) and
    ``hint`` is a constant human sentence. The message NEVER contains the rejected value: inputs here include Wi-Fi
    passphrases, PINs and tokens, and an exception text ends up in logs and in HTTP responses.
    """

    def __init__(self, field: str, code: str, hint: Optional[str] = None) -> None:
        self.field = field
        self.code = code
        self.hint = hint or ""
        text = "%s: %s" % (field, code)
        if hint:
            text += " (%s)" % hint
        super().__init__(text)

    def to_dict(self) -> dict:
        return {"field": self.field, "code": self.code, "hint": self.hint}
