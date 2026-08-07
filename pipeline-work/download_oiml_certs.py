#!/usr/bin/env python3
"""Mirror all OIML-CS certificates from oiml.org.

Phases:
  1. Page through the undocumented @@API/oiml-cs/certificates endpoint.
  2. Download every PDF that has a fileName, into certificates/<R-number>/.
  3. Write manifest.jsonl with full metadata + local path + download status.

Re-runnable: skips files already on disk. Safe to interrupt and resume.
"""
import json
import logging
import re
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

BASE = "https://www.oiml.org"
API = f"{BASE}/en/oiml-cs/@@API/oiml-cs/certificates"
PDF_BASE = f"{BASE}/en/files/pdf_c/"

ROOT = Path(__file__).resolve().parent
CERTS_DIR = ROOT / "certificates"
LOGS_DIR = ROOT / "_logs"
MANIFEST = ROOT / "manifest.jsonl"
LOGFILE = LOGS_DIR / "download.log"

PAGE_SIZE = 20
MAX_WORKERS = 4
INTER_PAGE_SEC = 0.3

R_RE = re.compile(r"^R0*(\d+)/(\d{4})-", re.IGNORECASE)


def make_session() -> requests.Session:
    s = requests.Session()
    retry = Retry(
        total=5,
        backoff_factor=1.0,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=["GET", "POST"],
        respect_retry_after_header=True,
    )
    s.mount("https://", HTTPAdapter(max_retries=retry, pool_connections=10, pool_maxsize=20))
    s.headers.update({
        "User-Agent": "oiml-cs-certificates-mirror/1.0 (+archival; respects 429/Retry-After)",
    })
    return s


def setup_logging() -> None:
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        handlers=[logging.FileHandler(LOGFILE, mode="a"), logging.StreamHandler(sys.stdout)],
    )


def folder_for(num: str) -> str:
    m = R_RE.match(num or "")
    if not m:
        return "_misc"
    return f"R{m.group(1)}/{m.group(2)}"


def fetch_all_pages(session: requests.Session):
    page = 1
    total = None
    while True:
        r = session.post(API, json={"page": page}, headers={"Accept": "application/json"}, timeout=30)
        r.raise_for_status()
        d = r.json()
        if total is None:
            total = d["nbCertificates"]
            logging.info("API reports %d total certificates", total)
        certs = d.get("certificates") or []
        if not certs:
            break
        for c in certs:
            yield c
        if page * PAGE_SIZE >= total:
            break
        page += 1
        time.sleep(INTER_PAGE_SEC)


def download_one(session: requests.Session, cert: dict):
    fname = cert.get("fileName")
    if not fname:
        return cert, "no_file", None
    dest = CERTS_DIR / folder_for(cert.get("num", "")) / fname
    if dest.exists() and dest.stat().st_size > 0:
        return cert, "exists", str(dest.relative_to(ROOT))
    url = PDF_BASE + fname
    try:
        r = session.get(url, timeout=60)
        if r.status_code == 404:
            return cert, "404", None
        r.raise_for_status()
        if not r.content.startswith(b"%PDF"):
            return cert, "not_pdf", None
        tmp = dest.with_suffix(dest.suffix + ".part")
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp.write_bytes(r.content)
        tmp.replace(dest)
        return cert, "downloaded", str(dest.relative_to(ROOT))
    except Exception as e:
        logging.warning("Failed %s: %s", fname, e)
        return cert, "error", None


def main() -> int:
    setup_logging()
    CERTS_DIR.mkdir(parents=True, exist_ok=True)

    session = make_session()

    logging.info("Phase 1: enumerating certificates via API")
    certs: list[dict] = []
    for c in fetch_all_pages(session):
        certs.append(c)
    logging.info("Enumerated %d certificates", len(certs))

    logging.info("Phase 2: downloading PDFs (%d workers)", MAX_WORKERS)
    counts: dict[str, int] = {}
    enriched: list[dict] = []
    n = len(certs)
    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as ex:
        futures = [ex.submit(download_one, session, c) for c in certs]
        for i, fut in enumerate(as_completed(futures), 1):
            cert, status, path = fut.result()
            counts[status] = counts.get(status, 0) + 1
            cert = dict(cert)
            cert["download_status"] = status
            cert["local_path"] = path
            enriched.append(cert)
            if i % 50 == 0 or i == n:
                logging.info("Progress %d/%d  counts=%s", i, n, counts)

    logging.info("Phase 3: writing manifest.jsonl")
    enriched.sort(key=lambda c: c.get("id", 0))
    with MANIFEST.open("w", encoding="utf-8") as f:
        for c in enriched:
            f.write(json.dumps(c, ensure_ascii=False) + "\n")

    for p in CERTS_DIR.rglob("*.part"):
        p.unlink(missing_ok=True)

    logging.info("Done. counts=%s", counts)
    print("\n=== SUMMARY ===")
    for k, v in sorted(counts.items()):
        print(f"  {k:12s} {v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
