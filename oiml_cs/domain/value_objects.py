"""Frozen value objects: RNumber, EditionYear, Issuer.

These are the atomic identities of the domain. They have no behavior beyond
validation, equality, and string form. Two certificates referring to
"R76" mean the same RNumber(76).
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from functools import cached_property


@dataclass(frozen=True, order=True)
class RNumber:
    """An OIML Recommendation number, e.g. R76. Canonical form has no leading zeros."""

    value: int

    def __post_init__(self) -> None:
        if self.value < 0:
            raise ValueError(f"RNumber must be non-negative, got {self.value}")

    def __str__(self) -> str:
        return f"R{self.value}"

    @classmethod
    def parse(cls, s: str) -> "RNumber":
        m = re.match(r"^\s*R0*(\d+)\s*$", s, re.IGNORECASE)
        if not m:
            raise ValueError(f"Cannot parse RNumber from {s!r}")
        return cls(int(m.group(1)))


@dataclass(frozen=True, order=True)
class EditionYear:
    """The edition year of a Recommendation, e.g. 2006."""

    value: int

    def __post_init__(self) -> None:
        if self.value < 1900 or self.value > 2100:
            raise ValueError(f"EditionYear out of plausible range: {self.value}")

    def __str__(self) -> str:
        return str(self.value)


@dataclass(frozen=True)
class Issuer:
    """An OIML Issuing Authority code, e.g. NL1, GB1, DK3.

    The country prefix is exposed via `country_code`. The full code (with
    sequence digit) is the canonical form.
    """

    code: str

    def __post_init__(self) -> None:
        if not re.match(r"^[A-Z]+\d+$", self.code):
            raise ValueError(f"Invalid Issuer code: {self.code!r}")

    def __str__(self) -> str:
        return self.code

    @cached_property
    def country_code(self) -> str:
        m = re.match(r"^([A-Z]+)\d+$", self.code)
        return m.group(1)

    @classmethod
    def parse(cls, s: str) -> "Issuer":
        s = s.strip().upper()
        if not re.match(r"^[A-Z]+\d+$", s):
            raise ValueError(f"Invalid Issuer code: {s!r}")
        return cls(s)
