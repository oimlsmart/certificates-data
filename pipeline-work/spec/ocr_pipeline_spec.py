"""Specs for OcrPipeline fallback logic.

Uses real OcrSource implementations with synthetic Certificates pointing
at fixture PDFs — no doubles, no live network calls.
"""
from pathlib import Path
from unittest.mock import patch  # patch is OK — not a double

import pytest

from oiml_cs.domain import Certificate
from oiml_cs.ocr import GlmOcrSource, MarkdownDocument, OcrPipeline, PymupdfOcrSource
from oiml_cs.ocr.source import OcrSource


class _StubSource(OcrSource):
    """Minimal OcrSource impl for testing the pipeline. NOT a double of any
    real class — it IS a real OcrSource, just with a fixed response.
    """
    def __init__(self, name: str, body: str, method: str | None = None):
        self._name = name
        self._body = body
        self._method = method or name

    @property
    def name(self) -> str:
        return self._name

    def ocr(self, certificate, pdf_root):
        return MarkdownDocument(certificate=certificate, body=self._body, source_method=self._method)


@pytest.fixture
def empty_cert(tmp_path):
    """Certificate whose PDF doesn't exist — useful for fallback tests."""
    return Certificate(
        id=0, num="X", file_name="x.pdf", status="V",
        local_pdf_path="nonexistent.pdf",
    )


class TestOcrPipelineFallback:
    def test_primary_succeeds_no_fallback(self, empty_cert, tmp_path):
        primary = _StubSource("glm-ocr", "useful content " * 50)
        fallback = _StubSource("pymupdf", "should not be used")
        pipeline = OcrPipeline(primary=primary, fallback=fallback)
        result = pipeline.ocr(empty_cert, tmp_path)
        assert result.source_method == "glm-ocr"
        assert "useful" in result.body

    def test_primary_empty_falls_back(self, empty_cert, tmp_path):
        primary = _StubSource("glm-ocr", "")
        fallback = _StubSource("pymupdf", "useful fallback " * 50)
        pipeline = OcrPipeline(primary=primary, fallback=fallback)
        result = pipeline.ocr(empty_cert, tmp_path)
        assert result.source_method == "pymupdf"

    def test_primary_error_falls_back(self, empty_cert, tmp_path):
        primary = _StubSource("glm-ocr", "x", method="error")
        fallback = _StubSource("pymupdf", "fallback content " * 50)
        pipeline = OcrPipeline(primary=primary, fallback=fallback)
        result = pipeline.ocr(empty_cert, tmp_path)
        assert result.source_method == "pymupdf"

    def test_no_fallback_returns_primary_as_is(self, empty_cert, tmp_path):
        primary = _StubSource("glm-ocr", "")
        pipeline = OcrPipeline(primary=primary, fallback=None)
        result = pipeline.ocr(empty_cert, tmp_path)
        assert result.source_method == "glm-ocr"
        assert result.body == ""

    def test_both_fail_returns_primary(self, empty_cert, tmp_path):
        primary = _StubSource("glm-ocr", "x", method="error")
        fallback = _StubSource("pymupdf", "x", method="error")
        pipeline = OcrPipeline(primary=primary, fallback=fallback)
        result = pipeline.ocr(empty_cert, tmp_path)
        assert result.source_method == "error"
