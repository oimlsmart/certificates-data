"""PymupdfOcrSource: in-process fitz text extraction.

Used as a fallback when GLM-OCR is unavailable or as a primary for
scanned-only PDFs that GLM can't parse. For OIML born-digital PDFs this
returns the embedded text directly.
"""
from __future__ import annotations

from pathlib import Path

import fitz

from oiml_cs.domain.certificate import Certificate
from oiml_cs.ocr.document import MarkdownDocument
from oiml_cs.ocr.source import OcrSource


class PymupdfOcrSource(OcrSource):
    """Direct text extraction from PDF via PyMuPDF (fitz)."""

    MIN_USEFUL_TEXT_LEN = 500

    @property
    def name(self) -> str:
        return "pymupdf"

    def ocr(self, certificate: Certificate, pdf_root: Path) -> MarkdownDocument:
        if not certificate.local_pdf_path:
            return MarkdownDocument(certificate=certificate, body="<!-- no PDF -->", source_method="error")
        pdf_path = pdf_root / certificate.local_pdf_path
        if not pdf_path.exists():
            return MarkdownDocument(certificate=certificate, body=f"<!-- PDF not found: {pdf_path} -->", source_method="error")

        doc = fitz.open(pdf_path)
        parts = []
        for i, page in enumerate(doc, 1):
            text = page.get_text(sort=True).strip()
            parts.append(f"## Page {i}\n\n```\n{text}\n```")
        doc.close()
        body = "\n\n".join(parts)
        return MarkdownDocument(certificate=certificate, body=body, source_method=self.name)
