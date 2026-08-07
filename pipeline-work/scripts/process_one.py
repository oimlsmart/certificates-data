#!/usr/bin/env python3
"""Process ONE recommendation (for testing / re-running).

Usage:
  python3 scripts/process_one.py --r R60
  python3 scripts/process_one.py --r R60 --edition 2017
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from oiml_cs.domain.value_objects import EditionYear, RNumber
from oiml_cs.infrastructure.manifest_repository import ManifestRepository
from oiml_cs.ocr import GlmOcrSource, OcrPipeline, PymupdfOcrSource
from oiml_cs.use_cases import ProcessRecommendation


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--r", required=True, help="R-number (e.g. R60)")
    p.add_argument("--edition", type=int, help="Edition year (default: latest)")
    p.add_argument("--sample-size", type=int, default=100)
    return p.parse_args()


def main() -> int:
    args = parse_args()
    repo = ManifestRepository(ROOT / "manifest.jsonl")
    r = RNumber.parse(args.r)
    edition = EditionYear(args.edition) if args.edition else None

    uc = ProcessRecommendation(
        manifest_repo=repo,
        ocr_pipeline=OcrPipeline(primary=GlmOcrSource(), fallback=PymupdfOcrSource()),
        output_root=ROOT,
        sample_size=args.sample_size,
    )
    result = uc.execute(r, edition)
    print(f"\nDone: {result.recommendation}/{result.edition.year}, {result.parsed_count} parsed, {result.ocr_error_count} errors")
    print(f"Schema: {result.schema_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
