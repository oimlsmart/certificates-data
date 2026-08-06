"""GlmExtractor: GLM chat completion API → ParsedCertificate (layered).

Calls https://api.z.ai/api/paas/v4/chat/completions with a system prompt
describing the layered schema and a user prompt containing the GLM-OCR
markdown. The model returns strict JSON conforming to the schema.

Caches per (markdown + vocabulary + prompt_version).
"""
from __future__ import annotations

import hashlib
import json
import re
import time
from pathlib import Path

import requests

from oiml_cs.extraction.parsed_certificate import ParsedCertificate
from oiml_cs.extraction.source import Extractor
from oiml_cs.ocr.document import MarkdownDocument
from oiml_cs.ocr.glm_source import _read_api_key

ENDPOINT = "https://api.z.ai/api/paas/v4/chat/completions"
DEFAULT_CACHE_DIR = Path("_glm_extract_cache")
DEFAULT_MODEL = "glm-4.5v"
PROMPT_VERSION = "2026-07-20-v3-structured-values-units"
READ_TIMEOUT = 300
OPEN_TIMEOUT = 30

SYSTEM_PROMPT = """\
You are an OIML-CS certificate extractor. Read the markdown (which is GLM-OCR
output of an OIML Certificate of Conformity PDF) and produce a JSON object
following the layered schema below.

## Layered schema

```yaml
certificate:                        # document-level
  number, scheme (A|B), project_number, page_total, member_state,
  date_issued, oiml_issuer_id
issuing_authority:
  name, address_lines[], person_responsible, person_title, phone, email,
  website, oiml_issuer_id
applicants[]:
  name, address_lines[]
manufacturers[]:
  name, address_lines[]
certified_type:
  category                          # "Load cell", "Indicator", "Measuring system", "Fuel dispenser", "Taximeter", "Gas meter", ...
  type_designations[]               # all type/model identifiers mentioned
  module_designation                # "Analog load cell" | "Not applicable" | null
  description                       # free-text description if present
model_family:                       # include ONLY if cert covers >1 model variant
  family_name                       # explicit family name if any, else null
  models[]:                         # one entry per variant
    model_id, label, attributes{}
components[]:                       # include ONLY if cert names sub-assemblies
  role, type_designations[], alternatives ("OR"|"AND"|null), characteristics{}
characteristics:
  type_level:                       # whole-cert attributes — single value
    <label>: {value, unit, footnote_markers[]}
  model_level[]:                    # attribute × model matrix
    attribute, unit, values[]: {model, value, footnote_markers[]}
  config_level[]:                   # attribute × config-axis matrix
    attribute, axis, values[]: {condition, value}
matrix_tables[]:                    # preserve multi-dim tables that don't fit elsewhere
  name, columns[], rows[] (object per row), description, footnotes[]
recommendation:
  id (canonical, e.g. "R60" not "OIML R 60"), edition (int), amendment, scheme, accuracy_classes[]
test_reports[]:
  id, date, pages, role             # role: type_evaluation_report | test_report | documentation_file | evaluation_report
revision_history[]:
  revision (string, e.g. "0" not 0), date, changes
footnotes[]:
  marker, text
```

## Rules

1. **Canonical labels.** Use snake_case canonical labels. NEVER include LaTeX
   (`$...$`, `\\mathrm{}`, `\\text{}`, `\\circ`, etc.), footnote markers (`(1)`,
   `^{(1)}$`, `[1]`), or trailing punctuation. Examples:
   - `Maximum capacity ($E_{\\mathrm{max}}$)` → `maximum_capacity`
   - `Max. number of load cell intervals n<sub>LC</sub>` → `max_load_cell_intervals_nlc`
   - `Ratio of minimum LC Verification interval(1) Y=Emax/vmin` → `ratio_y_emax_over_vmin`
   - `Apportionment factor pLC` → `apportionment_factor_plc`

2. **Structured values — STRICT.** Every characteristic value MUST be an
   object with this shape, separating the numeric value from the unit:

   ```json
   {
     "value": <number | {min, max} | string>,
     "unit_symbol": "°C" | "V" | "kg" | null,
     "unit_id": "u:degree_Celsius" | null,
     "footnote_markers": ["1)"]
   }
   ```

   Rules for `value`:
   - **Numbers, not strings.** `3000` not `"3000"`. `0.8` not `"0.8"`.
   - **Decimal point.** Use `.` as the decimal separator, never `,`. Convert
     European `0,7` → `0.7`. Convert `1,5` → `1.5`. Convert `0,01` → `0.01`.
   - **Ranges.** `0-9.999`, `0...120000`, `110-240`, `-10°C/+40°C` (after
     unit extraction) all become `{min: <num>, max: <num>}`. Open-ended
     ranges use `null` for the missing bound: `≥1000` → `{min: 1000, max: null}`.
   - **Lists of values.** `25,30,50,60,75,90` (multiple Emax values) is a
     MODEL MATRIX — emit `model_level` entries, NOT a list-as-value.
   - **Formulas/symbols.** When the value is a formula like `Emax/14000` or
     a symbol like `Emax`, keep it as a string: `"value": "Emax/14000"`.
   - **Pure units or footnote markers are NOT values.** If the cell content
     is just `kg`, `t`, `Ω`, or `1)`, do not record the characteristic at all
     — the actual value is missing.

3. **Unit separation.** Pull the unit OUT of the value string and put it in
   `unit_symbol`. Match the canonical Unicode form when possible:
   - `+5°C/+40°C` → `value: {min: 5, max: 40}, unit_symbol: "°C"`
   - `110-240V AC 50/60Hz` → SPLIT into two characteristics:
     - `power_supply_voltage: {value: {min: 110, max: 240}, unit_symbol: "V"}`
     - `power_supply_frequency: {value: {min: 50, max: 60}, unit_symbol: "Hz"}`
     - `power_supply_type: {value: "AC"}`
   - `0-15%vol` → `value: {min: 0, max: 15}, unit_symbol: "%vol"` (%vol
     isn't in unitsdb; use the raw symbol)
   - `1ppmvol` → `value: 1, unit_symbol: "ppmvol"`
   - `0,01%vol` → `value: 0.01, unit_symbol: "%vol"` (decimal fixed!)
   - `≤2.5m/s` → `value: {min: null, max: 2.5}, unit_symbol: "m/s"`
   - `0.8` → `value: 0.8, unit_symbol: null` (dimensionless)
   - `150% of Emax` → `value: 150, unit_symbol: "%"` and a SEPARATE
     characteristic `safe_overload_reference: {value: "Emax"}` for the
     reference. (Or omit if too noisy.)

   Leave `unit_id: null` unless you are certain of the unitsdb ID. The
   caller will look up `unit_symbol` in unitsdb.

4. **Matrix detection — MOST IMPORTANT.** Many OIML certs cover a FAMILY of
   instrument models, where attributes vary per model. Detect this and put
   varying attributes in `model_level`, NOT `type_level`.

   **R60 example.** Markdown contains:
   ```
   <table><tr><td>Maximum capacity Emax</td><td>t</td><td>25,30,50,60,75,90</td></tr></table>
   ```
   This is a single field with 6 comma-separated values. It means the cert
   covers 6 model variants with Emax ∈ {25, 30, 50, 60, 75, 90} t. EXTRACT as:
   ```json
   "model_family": {
     "models": [
       {"model_id": "Emax=25t"}, {"model_id": "Emax=30t"}, {"model_id": "Emax=50t"},
       {"model_id": "Emax=60t"}, {"model_id": "Emax=75t"}, {"model_id": "Emax=90t"}
     ]
   },
   "characteristics": {
     "model_level": [
       {
         "attribute": "maximum_capacity",
         "unit_symbol": "t",
         "values": [
           {"model": "Emax=25t", "value": 25},
           {"model": "Emax=30t", "value": 30},
           ...
         ]
       }
     ]
   }
   ```

   **R137 example.** Markdown contains an explicit 2-D table:
   ```
   <table>
   <tr><td>Size G</td><td>Qmax(m³/h)</td><td>Qt(m³/h)</td><td>Qmin(m³/h)</td>...</tr>
   <tr><td>G2.5</td><td>4.0</td><td>0.4</td><td>0.025</td>...</tr>
   <tr><td>G1.6</td><td>2.5</td><td>0.25</td><td>0.016</td>...</tr>
   </table>
   ```
   EXTRACT as `matrix_tables[]` AND populate `model_family.models` and
   `characteristics.model_level`:
   ```json
   "model_family": {
     "family_name": null,
     "models": [{"model_id": "G1.6"}, {"model_id": "G2.5"}]
   },
   "matrix_tables": [
     {
       "name": "Flow characteristics by size",
       "columns": ["size", "qmax", "qt", "qmin", "cyclic_volume", "max_pressure_loss", "pmax"],
       "column_units": [null, "m³/h", "m³/h", "m³/h", "dm³", "Pa", "kPa"],
       "rows": [
         {"size": "G2.5", "qmax": 4.0, "qt": 0.4, "qmin": 0.025, "cyclic_volume": 0.9, "max_pressure_loss": 200, "pmax": 50},
         {"size": "G1.6", "qmax": 2.5, "qt": 0.25, "qmin": 0.016, "cyclic_volume": 0.9, "max_pressure_loss": 200, "pmax": 50}
       ]
     }
   ],
   "characteristics": {
     "model_level": [
       {"attribute": "qmax", "unit_symbol": "m³/h", "values": [{"model": "G1.6", "value": 2.5}, {"model": "G2.5", "value": 4.0}]},
       {"attribute": "qt", "unit_symbol": "m³/h", "values": [{"model": "G1.6", "value": 0.25}, {"model": "G2.5", "value": 0.4}]},
       {"attribute": "qmin", "unit_symbol": "m³/h", "values": [{"model": "G1.6", "value": 0.016}, {"model": "G2.5", "value": 0.025}]}
     ]
   }
   ```

5. **Configuration axes.** When attributes vary by configuration (not by model
   — e.g. 2-sensor-row vs 4-sensor-row setups; static vs dynamic weighing), use
   `characteristics.config_level` with `axis` describing the dimension. Values
   follow the same structured form: `{condition, value, unit_symbol}`.

6. **Components.** For complex instruments (e.g. "Measuring sensor FM01 +
   Pulser P2 + Calculating device WB"), record each as a `components[]` entry
   with `role`, `type_designations`, and any sub-characteristics. When the
   cert offers alternatives (e.g. "Transmitter UMC4 OR UMC4-RM"), record
   `alternatives: "OR"`.

7. **Footnotes.** Extract footnote definitions (e.g. "1) This applies only to
   single-interval instruments.") into `footnotes[]`. When a value references
   a footnote, record the marker in `footnote_markers` on that value (e.g.
   `{"value": {"min": 1, "max": null}, "unit_symbol": "g", "footnote_markers": ["1)"]}`).

8. **Don't fabricate.** If a field is not present in the markdown, omit it.
   Empty strings are not values — use null or omit.

9. **Output format.** Return a single JSON object (no markdown fences, no
   commentary). The JSON must be parseable by `json.loads`.

10. **Multilingual.** Some certs are bilingual (English + French). Extract the
    English version; ignore the parallel translation.

11. **Image markers.** Ignore `![](page=N,bbox=...)` lines — they are GLM-OCR
    artifacts.

12. **Party layout variations.** Different issuing authorities use different
    layouts (NMi uses tables with Applicant/Manufacturer labels; PTB uses
    "Name:" / "Address:" labels; some certs have "Manufacturer of the
    certified type is the applicant"). Parse all of these correctly.
"""


class GlmExtractor(Extractor):
    """GLM chat-completion extractor with on-disk cache."""

    def __init__(
        self,
        cache_dir: Path | None = None,
        api_key: str | None = None,
        model: str = DEFAULT_MODEL,
    ):
        self._cache_dir = cache_dir or DEFAULT_CACHE_DIR
        self._cache_dir.mkdir(parents=True, exist_ok=True)
        self._api_key = api_key or _read_api_key()
        self._model = model

    @property
    def name(self) -> str:
        return "glm-extract"

    def extract(
        self,
        document: MarkdownDocument,
        vocabulary: dict | None = None,
    ) -> ParsedCertificate:
        cache_key = self._cache_key(document.body, vocabulary)
        cached = self._read_cache(cache_key)
        if cached is not None:
            return ParsedCertificate.from_json(cached)

        user_prompt = self._build_user_prompt(document.body, vocabulary)
        response_text = self._call_api(user_prompt)
        json_obj = self._parse_json(response_text)
        if json_obj is None:
            return ParsedCertificate(extraction_warnings=[
                f"GLM returned unparseable JSON. Raw output (first 500 chars): {response_text[:500]}"
            ])

        self._write_cache(cache_key, json_obj)
        return ParsedCertificate.from_json(json_obj)

    # ── prompt construction ───────────────────────────────────────────

    @staticmethod
    def _build_user_prompt(markdown: str, vocabulary: dict | None) -> str:
        parts = []
        if vocabulary:
            parts.append("## Per-R vocabulary")
            parts.append("```yaml")
            parts.append(yaml_dump_compact(vocabulary))
            parts.append("```")
            parts.append("")
            parts.append("Use these canonical labels when extracting `characteristics`. "
                         "For labels not in the vocabulary, invent a snake_case canonical name.")
            parts.append("")
        parts.append("## Certificate markdown")
        parts.append("```markdown")
        parts.append(markdown)
        parts.append("```")
        parts.append("")
        parts.append("Return one JSON object conforming to the layered schema. No prose, no markdown fences around the JSON.")
        return "\n".join(parts)

    # ── API call ──────────────────────────────────────────────────────

    def _call_api(self, user_prompt: str) -> str:
        body = {
            "model": self._model,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_prompt},
            ],
            "temperature": 0.0,
            "response_format": {"type": "json_object"},
        }
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
                if response.status_code < 500:
                    data = response.json()
                    return data["choices"][0]["message"]["content"]
            except requests.RequestException as e:
                last_exc = e
            time.sleep(2 ** attempt)
        if last_exc:
            raise last_exc
        raise RuntimeError(f"GLM extract API failed after 3 retries (last status {response.status_code}): {response.text[:300]}")

    @staticmethod
    def _parse_json(text: str) -> dict | None:
        """GLM should return raw JSON, but be defensive: strip code fences if present."""
        text = text.strip()
        if text.startswith("```"):
            # strip ```json or ``` fence
            text = re.sub(r"^```(?:json)?\s*\n", "", text)
            text = re.sub(r"\n```\s*$", "", text)
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            # Last resort: find the first { and last } and try to parse that
            m = re.search(r"\{.*\}", text, re.DOTALL)
            if m:
                try:
                    return json.loads(m.group(0))
                except json.JSONDecodeError:
                    return None
            return None

    # ── cache ─────────────────────────────────────────────────────────

    def _cache_key(self, markdown: str, vocabulary: dict | None) -> str:
        vocab_hash = hashlib.sha256(
            json.dumps(vocabulary, sort_keys=True, default=str).encode()
        ).hexdigest()[:8] if vocabulary else "no-vocab"
        md_hash = hashlib.sha256(markdown.encode()).hexdigest()[:16]
        return f"{PROMPT_VERSION}-{self._model}-{md_hash}-{vocab_hash}"

    def _read_cache(self, key: str) -> dict | None:
        cache_path = self._cache_dir / f"{key}.json"
        if cache_path.exists():
            try:
                return json.loads(cache_path.read_text())
            except json.JSONDecodeError:
                return None
        return None

    def _write_cache(self, key: str, data: dict) -> None:
        (self._cache_dir / f"{key}.json").write_text(json.dumps(data, ensure_ascii=False, indent=2))


def yaml_dump_compact(d: dict) -> str:
    """Compact YAML for prompt embedding."""
    import yaml
    return yaml.safe_dump(d, allow_unicode=True, sort_keys=False, default_flow_style=False, width=120)
