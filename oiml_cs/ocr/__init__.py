"""OCR subsystem: PDF → markdown.

Public API:
  - MarkdownDocument: value object holding OCR output + provenance
  - OcrSource: interface (ABC)
  - GlmOcrSource: GLM-OCR via z.ai layout_parsing API
  - PymupdfOcrSource: pymupdf/fitz direct text extraction
  - OcrPipeline: orchestrator with primary + fallback
"""
from oiml_cs.ocr.document import MarkdownDocument
from oiml_cs.ocr.glm_source import GlmOcrSource
from oiml_cs.ocr.pipeline import OcrPipeline
from oiml_cs.ocr.pymupdf_source import PymupdfOcrSource
from oiml_cs.ocr.source import OcrSource

__all__ = [
    "GlmOcrSource",
    "MarkdownDocument",
    "OcrPipeline",
    "OcrSource",
    "PymupdfOcrSource",
]
