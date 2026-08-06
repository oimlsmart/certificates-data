"""ManifestRepository: single source of truth for certificate records.

Reads `manifest.jsonl` once, exposes domain objects. All other modules
consume `Certificate` instances, never raw dicts.
"""
from __future__ import annotations

import json
from functools import cached_property
from pathlib import Path

from oiml_cs.domain.certificate import Certificate
from oiml_cs.domain.edition import Edition
from oiml_cs.domain.recommendation import Recommendation
from oiml_cs.domain.value_objects import EditionYear, RNumber


class ManifestRepository:
    """In-memory view of the OIML-CS manifest.

    Reads once on first access (cached). Subsequent calls return filtered
    projections without re-reading the file.
    """

    def __init__(self, manifest_path: Path):
        self._manifest_path = manifest_path

    @cached_property
    def all_certificates(self) -> list[Certificate]:
        return [
            Certificate.from_manifest_row(json.loads(line))
            for line in self._manifest_path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]

    def recommendations(self) -> list[Recommendation]:
        """All distinct Recommendations present in the manifest."""
        seen: set[RNumber] = set()
        for c in self.all_certificates:
            if c.recommendation is not None:
                seen.add(c.recommendation)
        return [Recommendation(r) for r in sorted(seen)]

    def certificates_for(self, r_number: RNumber, edition_year: EditionYear) -> list[Certificate]:
        return [
            c for c in self.all_certificates
            if c.recommendation == r_number and c.edition_year == edition_year
        ]

    def editions_of(self, r_number: RNumber) -> list[EditionYear]:
        years = {
            c.edition_year
            for c in self.all_certificates
            if c.recommendation == r_number and c.edition_year is not None
        }
        return sorted(years)

    def latest_edition(self, r_number: RNumber) -> EditionYear | None:
        editions = self.editions_of(r_number)
        return editions[-1] if editions else None

    def certificates_for_latest_edition(self, r_number: RNumber) -> list[Certificate]:
        latest = self.latest_edition(r_number)
        if latest is None:
            return []
        return self.certificates_for(r_number, latest)

    def edition(self, r_number: RNumber, year: EditionYear) -> Edition:
        return Edition(r_number, year)
