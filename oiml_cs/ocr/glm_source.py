"""GlmOcrSource: calls z.ai layout_parsing API directly (HTTP POST).

Reuses the on-disk cache format from the Ruby GlmOcr library:
  _glm_ocr_cache/<sha256(path|start|end)[0:16]>.json

This means cache files written by either implementation are interchangeable.
"""
from __future__ import annotations

import base64
import hashlib
import json
import time
from pathlib import Path

import requests

from oiml_cs.domain.certificate import Certificate
from oiml_cs.ocr.document import MarkdownDocument
from oiml_cs.ocr.source import OcrSource

ENDPOINT = "https://api.z.ai/api/paas/v4/layout_parsing"
DEFAULT_KEY_FILE = Path.home() / ".zai-api-key"
DEFAULT_CACHE_DIR = Path("_glm_ocr_cache")
MAX_BYTES = 50 * 1024 * 1024
PAGES_PER_CHUNK = 100
READ_TIMEOUT = 600
OPEN_TIMEOUT = 30


def _read_api_key() -> str:
    import os
    key = os.environ.get("Z_AI_API_KEY")
    if key:
        return key
    if DEFAULT_KEY_FILE.exists():
        text = DEFAULT_KEY_FILE.read_text().strip()
        if text.startswith("export "):
            text = text.split("=", 1)[1].strip().strip("'\"")
        return text
    raise RuntimeError(f"Z_AI_API_KEY not set and {DEFAULT_KEY_FILE} not found")


class GlmOcrSource(OcrSource):
    """GLM-OCR via z.ai. Caches per (path, start_page, end_page)."""

    def __init__(self, cache_dir: Path | None = None, api_key: str | None = None):
        self._cache_dir = cache_dir or DEFAULT_CACHE_DIR
        self._cache_dir.mkdir(parents=True, exist_ok=True)
        self._api_key = api_key or _read_api_key()

    @property
    def name(self) -> str:
        return "glm-ocr"

    def ocr(self, certificate: Certificate, pdf_root: Path) -> MarkdownDocument:
        if not certificate.local_pdf_path:
            return MarkdownDocument(certificate=certificate, body="<!-- no PDF -->", source_method="error")
        pdf_path = pdf_root / certificate.local_pdf_path
        if not pdf_path.exists():
            return MarkdownDocument(certificate=certificate, body=f"<!-- PDF not found: {pdf_path} -->", source_method="error")

        pdf_bytes = pdf_path.read_bytes()
        if len(pdf_bytes) > MAX_BYTES:
            return MarkdownDocument(certificate=certificate, body="<!-- PDF exceeds 50 MB limit -->", source_method="error")

        num_pages = _page_count(pdf_path)
        try:
            body = self._ocr_pdf(pdf_path, pdf_bytes, num_pages)
            return MarkdownDocument(certificate=certificate, body=body, source_method=self.name)
        except Exception as e:
            return MarkdownDocument(certificate=certificate, body=f"<!-- OCR ERROR: {e} -->", source_method="error")

    def _ocr_pdf(self, pdf_path: Path, pdf_bytes: bytes, num_pages: int) -> str:
        """Single PDF → markdown. Mirrors Ruby GlmOcr#ocr_pdf behavior."""
        if num_pages <= PAGES_PER_CHUNK:
            return self._chunk(pdf_path, pdf_bytes, 1, num_pages)
        parts = []
        for start_page, end_page in _split_windows(num_pages):
            # For >100-page PDFs we'd need to physically split via pdftk. Certs
            # are typically 2-5 pages, so this path is unused for OIML certs.
            # Implementing it for completeness:
            raise RuntimeError(
                f"PDF has {num_pages} pages (> {PAGES_PER_CHUNK}); "
                f"splitting not implemented in Python source — use Ruby driver."
            )
        return "\n\n<!-- page-break -->\n\n".join(parts)

    def _chunk(self, pdf_path: Path, pdf_bytes: bytes, start_page: int, end_page: int) -> str:
        cache_key = self._cache_key(pdf_path, start_page, end_page)
        cached = self._read_cache(cache_key)
        if cached is not None:
            return cached.get("md_results", "")

        data_url = "data:application/pdf;base64," + base64.b64encode(pdf_bytes).decode("ascii")
        body = {
            "model": "glm-ocr",
            "file": data_url,
            "start_page_id": start_page,
            "end_page_id": end_page,
        }
        response = self._post_with_retry(body)
        result = response.json()
        if result.get("error") or (result.get("code") and result.get("code") != 200):
            raise RuntimeError(f"GLM-OCR error: {result}")
        self._write_cache(cache_key, result)
        return result.get("md_results", "")

    def _post_with_retry(self, body: dict) -> requests.Response:
        last_exc: Exception | None = None
        for attempt in range(3):
            try:
                response = requests.post(
                    ENDPOINT,
                    json=body,
                    headers={
                        "Authorization": f"Bearer {self._api_key}",
                        "Content-Type": "application/json",
                    },
                    timeout=(OPEN_TIMEOUT, READ_TIMEOUT),
                )
                if response.status_code < 500 or 400 <= response.status_code < 500:
                    return response
            except requests.RequestException as e:
                last_exc = e
            time.sleep(2 ** attempt)
        if last_exc:
            raise last_exc
        return response  # final attempt's response

    def _cache_key(self, pdf_path: Path, start_page: int, end_page: int) -> str:
        # Match Ruby lib's key derivation: sha256(f"{path}|{start}|{end}")[0:16]
        return hashlib.sha256(f"{pdf_path}|{start_page}|{end_page}".encode()).hexdigest()[:16]

    def _read_cache(self, key: str) -> dict | None:
        cache_path = self._cache_dir / f"{key}.json"
        if cache_path.exists():
            return json.loads(cache_path.read_text())
        return None

    def _write_cache(self, key: str, data: dict) -> None:
        (self._cache_dir / f"{key}.json").write_text(json.dumps(data))


def _page_count(pdf_path: Path) -> int:
    try:
        import fitz
        doc = fitz.open(pdf_path)
        n = doc.page_count
        doc.close()
        return n
    except Exception:
        return 1


def _split_windows(num_pages: int) -> list[tuple[int, int]]:
    """Half-open windows of PAGES_PER_CHUNK pages each."""
    windows: list[tuple[int, int]] = []
    start = 1
    while start <= num_pages:
        end = min(start + PAGES_PER_CHUNK - 1, num_pages)
        windows.append((start, end))
        start = end + 1
    return windows
