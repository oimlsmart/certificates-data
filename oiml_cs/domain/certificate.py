"""Certificate: a single OIML-CS certificate record from the manifest."""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any

from oiml_cs.domain.value_objects import EditionYear, Issuer, RNumber

# fileName format: r076-2006-nl1-2024-05-rev2.pdf
# Captures: R-number, edition year, issuer, certificate year, sequence
_FILE_NAME_RE = re.compile(
    r"^r0*(\d+)-(\d{4})-([a-z]+\d+)-(\d{4})-(\d+)",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class Certificate:
    """A single OIML-CS certificate, as registered in the OIML database.

    Parsed fields (`recommendation`, `edition_year`, `issuer`, `cert_year`) are
    derived from `file_name` per the OIML naming convention. They are None for
    certs whose fileName doesn't match the standard pattern.
    """

    id: int
    num: str
    file_name: str | None
    status: str
    applicant: str | None = None
    issuing_year: str | None = None
    recommendation: RNumber | None = None
    edition_year: EditionYear | None = None
    issuer: Issuer | None = None
    cert_year: int | None = None
    local_pdf_path: str | None = None

    @classmethod
    def from_manifest_row(cls, row: dict[str, Any]) -> "Certificate":
        file_name = row.get("fileName") or None
        rec, ed, iss, cert_year = _parse_file_name(file_name) if file_name else (None, None, None, None)
        return cls(
            id=int(row["id"]),
            num=row.get("num") or "",
            file_name=file_name,
            status=row.get("status") or "Unknown",
            applicant=row.get("applicant") or None,
            issuing_year=str(row["issuingYear"]) if row.get("issuingYear") else None,
            recommendation=rec,
            edition_year=ed,
            issuer=iss,
            cert_year=cert_year,
            local_pdf_path=row.get("local_path") or None,
        )

    @property
    def stem(self) -> str:
        """Stem for output filenames (e.g. 'r076-2006-nl1-2024-05-rev2')."""
        if not self.file_name:
            return f"cert-{self.id}"
        return self.file_name[:-4] if self.file_name.endswith(".pdf") else self.file_name


def _parse_file_name(file_name: str) -> tuple[RNumber | None, EditionYear | None, Issuer | None, int | None]:
    m = _FILE_NAME_RE.match(file_name)
    if not m:
        return None, None, None, None
    try:
        return (
            RNumber(int(m.group(1))),
            EditionYear(int(m.group(2))),
            Issuer(m.group(3).upper()),
            int(m.group(4)),
        )
    except ValueError:
        return None, None, None, None
