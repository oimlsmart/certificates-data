"""Process ALL recommendations in PARALLEL — GLM-extract (no regex) + per-R schema.

Usage:
  python3 scripts/process_all_parallel.py                 # all R's, 4 workers
  python3 scripts/process_all_parallel.py --workers 8     # 8 parallel
  python3 scripts/process_all_parallel.py --only R60,R117
  python3 scripts/process_all_parallel.py --skip R31
  python3 scripts/process_all_parallel.py --sample-size 30
  python3 scripts/process_all_parallel.py --dry-run
"""
from __future__ import annotations

import argparse
import sys
import traceback
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import yaml  # noqa: E402

from oiml_cs.domain.certificate import Certificate  # noqa: E402
from oiml_cs.domain.edition import Edition  # noqa: E402
from oiml_cs.domain.value_objects import EditionYear, RNumber  # noqa: E402
from oiml_cs.extraction.glm_extractor import GlmExtractor  # noqa: E402
from oiml_cs.extraction.parsed_certificate import ParsedCertificate  # noqa: E402
from oiml_cs.infrastructure.manifest_repository import ManifestRepository  # noqa: E402
from oiml_cs.ocr.document import MarkdownDocument  # noqa: E402
from oiml_cs.ocr.pipeline import OcrPipeline  # noqa: E402
from oiml_cs.ocr.glm_source import GlmOcrSource  # noqa: E402
from oiml_cs.ocr.pymupdf_source import PymupdfOcrSource  # noqa: E402
from oiml_cs.sampling.stratified_sampler import StratifiedSampler  # noqa: E402
from oiml_cs.serialization.yaml_serializer import CertificateYamlSerializer  # noqa: E402


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--only")
    p.add_argument("--skip")
    p.add_argument("--sample-size", type=int, default=100)
    p.add_argument("--workers", type=int, default=4)
    p.add_argument("--dry-run", action="store_true")
    return p.parse_args()


def select_targets(repo, only, skip):
    all_rs = [r.r_number for r in repo.recommendations()]
    only_set = {RNumber.parse(x.strip()) for x in only.split(",")} if only else None
    skip_set = {RNumber.parse(x.strip()) for x in skip.split(",")} if skip else set()
    return sorted(r for r in all_rs
                  if (only_set is None or r in only_set) and r not in skip_set)


def extract_one(
    extractor: GlmExtractor,
    serializer: CertificateYamlSerializer,
    output_root: Path,
    cert: Certificate,
    edition: Edition,
    ocr_pipeline: OcrPipeline | None = None,
) -> tuple[Certificate, ParsedCertificate, Exception | None]:
    """Extract + serialize one cert. Thread-safe: each cert writes to its own file
    and has its own cache key. If markdown is missing and ocr_pipeline is provided,
    auto-OCR first. Returns (cert, parsed, error)."""
    md_path = output_root / "ocr_md" / edition.path_segment() / f"{cert.stem}.md"
    if not md_path.exists() or md_path.stat().st_size == 0:
        if ocr_pipeline is None:
            return cert, ParsedCertificate(), FileNotFoundError(f"No markdown: {md_path}")
        # Auto-OCR via GLM
        try:
            md_doc = ocr_pipeline.ocr(cert, output_root)
            md_path.parent.mkdir(parents=True, exist_ok=True)
            md_path.write_text(md_doc.to_markdown(), encoding="utf-8")
        except Exception as e:
            return cert, ParsedCertificate(), e
    try:
        doc = MarkdownDocument.from_file(md_path, cert)
        parsed = extractor.extract(doc)
        yaml_path = output_root / "yaml" / edition.path_segment() / f"{cert.stem}.yaml"
        yaml_path.parent.mkdir(parents=True, exist_ok=True)
        yaml_path.write_text(serializer.serialize(cert, parsed), encoding="utf-8")
        return cert, parsed, None
    except Exception as e:
        return cert, ParsedCertificate(), e


def process_recommendation(
    repo: ManifestRepository,
    extractor: GlmExtractor,
    serializer: CertificateYamlSerializer,
    output_root: Path,
    sample_size: int,
    workers: int,
    r_number: RNumber,
    edition_year: EditionYear | None = None,
    ocr_pipeline: OcrPipeline | None = None,
):
    if edition_year is None:
        edition_year = repo.latest_edition(r_number)
        if edition_year is None:
            raise RuntimeError(f"No editions for {r_number}")
    edition = repo.edition(r_number, edition_year)
    certs = repo.certificates_for(r_number, edition_year)
    sampled = StratifiedSampler(sample_size=sample_size).sample(certs)

    parsed_certs: list[ParsedCertificate] = []
    error_count = 0
    print(f"[{r_number}/{edition.year}] {len(sampled)} certs, {workers} workers...")
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [
            pool.submit(extract_one, extractor, serializer, output_root, cert, edition, ocr_pipeline)
            for cert in sampled
        ]
        for i, fut in enumerate(as_completed(futures), 1):
            cert, parsed, err = fut.result()
            parsed_certs.append(parsed)
            if err is not None:
                error_count += 1
                print(f"  [{r_number}] ERROR {cert.num}: {err}")
            if i % 20 == 0 or i == len(sampled):
                print(f"  [{r_number}/{edition.year}] {i}/{len(sampled)} done (errors: {error_count})")

    # Synthesize per-R schema (reuse logic from ProcessRecommendation)
    from oiml_cs.use_cases.process_recommendation import ProcessRecommendation
    dummy_uc = ProcessRecommendation.__new__(ProcessRecommendation)
    dummy_uc._out = output_root
    schema_path = dummy_uc._write_summary_schema(r_number, edition_year, parsed_certs)
    return parsed_certs, error_count, schema_path


def main() -> int:
    args = parse_args()
    repo = ManifestRepository(ROOT / "manifest.jsonl")
    targets = select_targets(repo, args.only, args.skip)
    print(f"Targets: {len(targets)} R-numbers, {args.workers} parallel workers per R")
    for r in targets:
        latest = repo.latest_edition(r)
        n_certs = len(repo.certificates_for_latest_edition(r)) if latest else 0
        sample = min(args.sample_size, n_certs)
        print(f"  {r}  latest={latest}  total={n_certs}  sample={sample}")
    if args.dry_run:
        return 0

    extractor = GlmExtractor()
    serializer = CertificateYamlSerializer()
    ocr_pipeline = OcrPipeline(primary=GlmOcrSource(), fallback=PymupdfOcrSource())
    results, errors = [], []
    for i, r in enumerate(targets, 1):
        print(f"\n=== [{i}/{len(targets)}] {r} ===")
        try:
            parsed_certs, err_count, schema_path = process_recommendation(
                repo=repo,
                extractor=extractor,
                serializer=serializer,
                output_root=ROOT,
                sample_size=args.sample_size,
                workers=args.workers,
                r_number=r,
                ocr_pipeline=ocr_pipeline,
            )
            results.append((r, len(parsed_certs), err_count, schema_path))
            print(f"  OK: extracted={len(parsed_certs)}, errors={err_count}, schema={schema_path}")
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
