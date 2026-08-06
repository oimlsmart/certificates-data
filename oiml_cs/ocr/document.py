"""MarkdownDocument: the value object produced by an OcrSource."""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

from oiml_cs.domain.certificate import Certificate


@dataclass(frozen=True)
class MarkdownDocument:
    """OCR output for a single certificate, with provenance."""

    certificate: Certificate
    body: str
    source_method: str  # "glm-ocr" | "pymupdf" | "tesseract" | "error"

    @classmethod
    def from_file(cls, path: Path, certificate: Certificate) -> "MarkdownDocument":
        text = path.read_text(encoding="utf-8")
        method = "unknown"
        for line in text.splitlines()[:20]:
            m = re.match(r"<!--\s*extraction_method:\s*([a-z\-]+)\s*-->", line)
            if m:
                method = m.group(1)
                break
        # Strip the provenance header for the body (it's regenerated on write)
        body = re.sub(
            r"^<!--[^>]*-->\n*(#[^\n]+\n)?",
            "",
            text,
            count=1,
        )
        return cls(certificate=certificate, body=body, source_method=method)

    def to_markdown(self) -> str:
        """Full markdown with provenance header (suitable for file output)."""
        c = self.certificate
        header = "\n".join([
            f"<!-- cert_id: {c.id} -->",
            f"<!-- num: {c.num} -->",
            f"<!-- applicant: {c.applicant or ''} -->",
            f"<!-- issuing_year: {c.issuing_year or ''} -->",
            f"<!-- status: {c.status} -->",
            f"<!-- issuer: {c.issuer or ''} -->",
            f"<!-- extraction_method: {self.source_method} -->",
            f"<!-- source_pdf: {c.local_pdf_path or ''} -->",
            "",
            f"# {c.num}",
            "",
        ])
        return header + self.body + "\n"
