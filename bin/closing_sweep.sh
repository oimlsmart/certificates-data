#!/bin/bash
# The closing sweep: retries extraction stragglers, refetches stuck raws,
# regenerates every derived dataset over the complete tiers, and writes the
# denominators report. Deterministic after the first two passes; logs to
# datasets/_closing.log. Safe to rerun; every step is idempotent.

cd "$(dirname "$0")/.." || exit 1
LOG=datasets/_closing.log
{
  echo "=== closing sweep $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="

  echo "--- sweep pass: retry rate-limit failures ---"
  ruby bin/extract_structured.rb --workers 8 2>&1 | tail -3

  echo "--- refetch pass: stuck raws (broken model JSON) ---"
  ruby bin/extract_structured.rb --workers 2 --refetch 2>&1 | tail -3

  echo "--- repair pass: model-assisted JSON repair ---"
  ruby bin/repair_broken_json.rb 2>&1 | tail -3

  echo "--- rederive _meta ---"
  ruby bin/rederive_meta.rb 2>&1 | tail -2

  echo "--- regenerate history ---"
  ruby bin/extract_history.rb 2>&1 | tail -7

  echo "--- regenerate organizations ---"
  ruby bin/build_organizations.rb 2>&1 | tail -3

  echo "--- regenerate stats ---"
  ruby bin/build_stats.rb 2>&1 | tail -4

  echo "--- denominators report ---"
  ruby bin/denominators_report.rb 2>&1

  echo "=== closing sweep complete $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
} >> "$LOG" 2>&1
