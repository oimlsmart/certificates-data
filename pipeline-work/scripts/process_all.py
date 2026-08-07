#!/usr/bin/env python3
"""Process ALL recommendations: GLM-extract (no regex) + per-R layered schema.

Usage:
  python3 scripts/process_all.py                       # all R's
  python3 scripts/process_all.py --only R60,R117       # subset
  python3 scripts/process_all.py --skip R31            # exclude
  python3 scripts/process_all.py --sample-size 30      # smaller per-R
  python3 scripts/process_all.py --dry-run             # list, don't execute
"""
from __future__ import annotations

import argparse
import sys
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import yaml  # noqa: E402

from oiml_cs.domain.value_objects import RNumber  # noqa: E402
from oiml_cs.extraction.glm_extractor import GlmExtractor  # noqa: E402
from oiml_cs.infrastructure.manifest_repository import ManifestRepository  # noqa: E402
from oiml_cs.use_cases.process_recommendation import ProcessRecommendation  # noqa: E402


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--only", help="Comma-separated R-numbers to process")
    p.add_argument("--skip", help="Comma-separated R-numbers to skip")
    p.add_argument("--sample-size", type=int, default=100)
    p.add_argument("--dry-run", action="store_true")
    return p.parse_args()


def select_targets(repo, only, skip):
    all_rs = [r.r_number for r in repo.recommendations()]
    only_set = {RNumber.parse(x.strip()) for x in only.split(",")} if only else None
    skip_set = {RNumber.parse(x.strip()) for x in skip.split(",")} if skip else set()
    return sorted(r for r in all_rs
                  if (only_set is None or r in only_set) and r not in skip_set)


def main() -> int:
    args = parse_args()
    repo = ManifestRepository(ROOT / "manifest.jsonl")
    targets = select_targets(repo, args.only, args.skip)
    print(f"Targets: {len(targets)} R-numbers")
    for r in targets:
        latest = repo.latest_edition(r)
        n_certs = len(repo.certificates_for_latest_edition(r)) if latest else 0
        sample = min(args.sample_size, n_certs)
        print(f"  {r}  latest={latest}  total={n_certs}  sample={sample}")
    if args.dry_run:
        return 0

    extractor = GlmExtractor()
    uc = ProcessRecommendation(
        manifest_repo=repo,
        extractor=extractor,
        output_root=ROOT,
        sample_size=args.sample_size,
    )

    results, errors = [], []
    for i, r in enumerate(targets, 1):
        print(f"\n[{i}/{len(targets)}] Processing {r}...")
        try:
            result = uc.execute(r)
            results.append(result)
            print(f"  OK: extracted={result.extracted_count}, errors={result.extraction_error_count}, "
                  f"matrix_tables={result.matrix_tables_count}, models={result.models_count}")
        except Exception as e:
            print(f"  FAILED: {e}")
            traceback.print_exc()
            errors.append((r, e))

    print(f"\n=== Summary ===")
    print(f"  Processed: {len(results)} R-numbers")
    print(f"  Failed:    {len(errors)}")
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main())
