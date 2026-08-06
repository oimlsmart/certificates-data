"""OcrSource: interface for all OCR backends."""
from __future__ import annotations

import abc

from oiml_cs.domain.certificate import Certificate
from oiml_cs.ocr.document import MarkdownDocument


class OcrSource(abc.ABC):
    """OCR backend. Implementations produce a MarkdownDocument from a Certificate."""

    @property
    @abc.abstractmethod
    def name(self) -> str:
        """Canonical name for this source (e.g. 'glm-ocr'). Used in provenance."""

    @abc.abstractmethod
    def ocr(self, certificate: Certificate, pdf_root) -> MarkdownDocument:
        """OCR the certificate's PDF and return a MarkdownDocument."""
        raise NotImplementedError
