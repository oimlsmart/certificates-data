"""Recommendation: an OIML Recommendation (e.g. R76)."""
from __future__ import annotations

from dataclasses import dataclass

from oiml_cs.domain.value_objects import RNumber


@dataclass(frozen=True)
class Recommendation:
    """An OIML Recommendation, identified by its R-number.

    Acts as a key into the manifest repository. Concrete certificate listings
    are returned by the manifest repository, not by this object (separation
    of concerns: domain identity vs. persistence).
    """

    r_number: RNumber

    def __str__(self) -> str:
        return str(self.r_number)

    def __post_init__(self) -> None:
        if not isinstance(self.r_number, RNumber):
            raise TypeError(f"r_number must be RNumber, got {type(self.r_number).__name__}")
