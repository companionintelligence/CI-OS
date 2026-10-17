"""Strict template rendering for the configuration files of hostapd, dnsmasq and nftables.

A template is a text file with ``@NAME@`` placeholders (upper case, digits, underscore). Rendering is deliberately
narrow:

* the placeholders in the template and the values given must match exactly - a missing value and a value nothing uses are
  both errors, so a template edit and its caller cannot drift apart;
* substitution is a single pass, so a value that happens to contain ``@OTHER@`` (an SSID may) is never expanded again;
* a value is text without NUL; unless the placeholder is declared multi-line it also has no newline or carriage return, so no
  value can add a directive line to a config file;
* the finished text is checked by :func:`lint_config`: every line is blank, a comment, or a ``key=value`` directive (with
  ``allow_bare`` also a bare keyword, as dnsmasq has) - the check that would catch an injection that got past the rest.

The templates themselves live in ``ci_setup/templates/`` and are read by :func:`load_template` (a whitelist of names, no
paths).
"""
from __future__ import annotations

import os
import re
from typing import Iterable, Mapping, Set

from .errors import CiSetupError

_PLACEHOLDER = re.compile(r"@([A-Z][A-Z0-9_]*)@")
_DIRECTIVE = re.compile(r"^[a-z0-9_.\[\]-]+=.*$")
_BARE = re.compile(r"^[a-z0-9_.-]+$")
TEMPLATE_NAMES = ("hostapd.conf.in", "dnsmasq.conf.in", "ci_setup.nft.in")
_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "templates")


class TemplateError(CiSetupError):
    """The template and the values disagree, or a value is not allowed."""


def load_template(name: str) -> str:
    """Read one of the shipped templates by name."""
    if name not in TEMPLATE_NAMES:
        raise TemplateError("unknown template")
    with open(os.path.join(_DIR, name), "r", encoding="utf-8") as fh:
        return fh.read()


def placeholders(template: str) -> Set[str]:
    return set(_PLACEHOLDER.findall(template))


def render_template(template: str, values: Mapping[str, str], multiline: Iterable[str] = ()) -> str:
    """Substitute ``values`` into ``template``. See the module docstring for the rules."""
    wanted = placeholders(template)
    given = set(values)
    if wanted != given:
        missing, extra = sorted(wanted - given), sorted(given - wanted)
        raise TemplateError("placeholders and values differ (missing: %s; unused: %s)" % (missing, extra))
    multi = set(multiline)
    for name, value in values.items():
        if not isinstance(value, str):
            raise TemplateError("value for %s is not text" % name)
        if "\x00" in value:
            raise TemplateError("value for %s contains NUL" % name)
        if name in multi:
            if "\r" in value:
                raise TemplateError("value for %s contains a carriage return" % name)
        elif "\n" in value or "\r" in value:
            raise TemplateError("value for %s contains a line break" % name)
    return _PLACEHOLDER.sub(lambda m: values[m.group(1)], template)


def lint_config(text: str, allow_bare: bool = False) -> None:
    """Raise :class:`TemplateError` unless every line of a rendered hostapd or dnsmasq file is blank, a ``#`` comment or a
    ``key=value`` directive (a bare keyword too with ``allow_bare``)."""
    if "\x00" in text or "\r" in text:
        raise TemplateError("NUL or carriage return in config")
    for n, line in enumerate(text.split("\n"), 1):
        if not line.strip() or line.startswith("#"):
            continue
        if line != line.strip():
            raise TemplateError("line %d has surrounding whitespace" % n)
        if _DIRECTIVE.fullmatch(line) or (allow_bare and _BARE.fullmatch(line)):
            continue
        raise TemplateError("line %d is not a directive" % n)
