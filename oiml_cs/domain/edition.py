"""Edition: a specific year's publication of a Recommendation."""
from __future__ import annotations

from dataclasses import dataclass

from oiml_cs.domain.value_objects import EditionYear, RNumber


@dataclass(frozen=True)
class Edition:
    """An edition of an OIML Recommendation, identified by (R, year).

    Example: Edition(RNumber(76), EditionYear(2006)) for OIML R76 Edition 2006.
    """

    r_number: RNumber
    year: EditionYear

    def __str__(self) -> str:
        return f"{self.r_number}/{self.year}"

    def __post_init__(self) -> None:
        if not isinstance(self.r_number, RNumber):
            raise TypeError(f"r_number must be RNumber, got {type(self.r_number).__name__}")
        if not isinstance(self.year, EditionYear):
            raise TypeError(f"year must be EditionYear, got {type(self.year).__name__}")

    def path_segment(self) -> str:
        """Folder name under certificates/, e.g. 'R76/2006'."""
        return f"{self.r_number}/{self.year}"
