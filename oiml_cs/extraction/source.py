"""Extractor interface — pluggable backends for markdown → ParsedCertificate."""
from __future__ import annotations

import abc

from oiml_cs.extraction.parsed_certificate import ParsedCertificate
from oiml_cs.ocr.document import MarkdownDocument


class Extractor(abc.ABC):
    """Extracts structured ParsedCertificate from a MarkdownDocument."""

    @property
    @abc.abstractmethod
    def name(self) -> str: ...

    @abc.abstractmethod
    def extract(
        self,
        document: MarkdownDocument,
        vocabulary: dict | None = None,
    ) -> ParsedCertificate:
        raise NotImplementedError
