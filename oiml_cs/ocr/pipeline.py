"""OcrPipeline: orchestrates primary + fallback OCR sources.

Strategy:
  1. Try primary source.
  2. If primary produced an empty/error document, try fallback.
  3. Track which source actually produced the result.
"""
from __future__ import annotations

from pathlib import Path

from oiml_cs.domain.certificate import Certificate
from oiml_cs.ocr.document import MarkdownDocument
from oiml_cs.ocr.source import OcrSource


class OcrPipeline:
    """Tries primary, falls back if primary produced no useful content."""

    def __init__(self, primary: OcrSource, fallback: OcrSource | None = None):
        self._primary = primary
        self._fallback = fallback

    def ocr(self, certificate: Certificate, pdf_root: Path) -> MarkdownDocument:
        result = self._primary.ocr(certificate, pdf_root)
        if self._is_useful(result):
            return result
        if self._fallback is None:
            return result
        fallback_result = self._fallback.ocr(certificate, pdf_root)
        return fallback_result if self._is_useful(fallback_result) else result

    @staticmethod
    def _is_useful(doc: MarkdownDocument) -> bool:
        if doc.source_method == "error":
            return False
        # Strip HTML comments and check for substantial content
        import re
        body = re.sub(r"<!--.*?-->", "", doc.body, flags=re.DOTALL).strip()
        return len(body) > 200
