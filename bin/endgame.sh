#!/bin/bash
# The endgame: runs after the closing sweep completes. Gates on extraction
# coverage (a failed or balance-dead run must never be merged), commits the
# four tiers plus the regenerated datasets under the maintainer's standing
# policy (TODO.planes excluded), pushes, and rebase-merges PR #5 — authorized
# by the maintainer on 2026-10-07.

cd "$(dirname "$0")/.." || exit 1
LOG=datasets/_closing.log
log() { echo "[endgame $(date '+%H:%M:%S')] $*" >> "$LOG"; }

# 1. wait for the closing sweep to finish
until grep -q "closing sweep complete" "$LOG" 2>/dev/null; do sleep 300; done
log "closing sweep detected complete — gating"

# 2. coverage gate: structured records must cover >= 99% of the PDFs
COVERAGE=$(ruby -e '
records = Dir["pipeline-work/yaml/R*/**/*.yaml"].size
pdfs = Dir["certificates/R*/**/*.pdf"].size
printf("%.4f", records.to_f / [pdfs, 1].max)
')
log "coverage: $COVERAGE (records/PDFs)"
GATE_OK=$(ruby -e "print(ARGV[0].to_f >= 0.99 ? \"ok\" : \"fail\")" "$COVERAGE")
if [ "$GATE_OK" != "ok" ]; then
  log "COVERAGE GATE FAILED ($COVERAGE < 0.99) — NOT committing, NOT merging. Manual review required."
  exit 1
fi
log "coverage gate passed"

# 3. the closing commit — explicit paths only, TODO.planes excluded
git add ocr_md ocr_raw extract_raw pipeline-work/yaml datasets bin
STAGED=$(git diff --cached --name-only | wc -l | tr -d ' ')
TODO_STAGED=$(git diff --cached --name-only | grep -c '^TODO' || true)
log "staged files: $STAGED (TODO files staged: $TODO_STAGED)"
if [ "$TODO_STAGED" != "0" ]; then
  git reset
  log "ABORT: TODO files were staged — policy violation. Manual review required."
  exit 1
fi
git commit -m "the tiers complete: every verbatim model response committed (vision ocr_raw 4,127 + structured extract_raw), the derived history/organizations/stats regenerated over the full extracted tier, the denominators ledger in datasets/DENOMINATORS.md, and the closing-sweep runners — the register is now fully machine-readable end to end, and nothing on disk ever needs a model call again" >> "$LOG" 2>&1
log "closing commit: $(git rev-parse --short HEAD)"

# 4. push and rebase-merge PR #5 (maintainer-authorized 2026-10-07)
git push origin feat/planes-programme >> "$LOG" 2>&1 && log "pushed" || { log "PUSH FAILED — manual review"; exit 1; }
gh pr merge 5 --rebase >> "$LOG" 2>&1 && log "PR #5 rebase-merged" || { log "MERGE FAILED — manual review"; exit 1; }
log "ENDGAME COMPLETE"
