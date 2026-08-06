"""Extraction subsystem: GLM-OCR markdown → ParsedCertificate (layered).

Replaces the regex-based `parsing/` package. Uses GLM chat completions to
extract structured JSON conforming to schema/_common_certificate_schema.yaml.

Public API:
  - ParsedCertificate: layered value object
  - Extractor (ABC) + GlmExtractor
"""
from oiml_cs.extraction.glm_extractor import GlmExtractor
from oiml_cs.extraction.parsed_certificate import ParsedCertificate
from oiml_cs.extraction.source import Extractor

__all__ = ["Extractor", "GlmExtractor", "ParsedCertificate"]
