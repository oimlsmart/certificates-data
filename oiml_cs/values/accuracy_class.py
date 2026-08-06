"""Value normalizers for OIML characteristic values.

These handle the messy reality of GLM extraction + OCR artifacts:
- accuracy_class: Roman numerals (R76-style), Letter+digit (R60-style),
  numeric (R117/R137-style), multi-class declarations, OCR mangling,
  nested {value: ...} wrappers.
"""
from __future__ import annotations

import re
from typing import Any

# ─── Helpers ────────────────────────────────────────────────────────────

def _unwrap_nested(value: Any) -> Any:
    """GLM sometimes returns {'value': X, 'unit_symbol': ...} where X is itself
    a value (number, string, list). Unwrap one level."""
    if isinstance(value, dict):
        inner = value.get("value")
        if inner is not None and (
            isinstance(inner, (int, float, str, list, dict))
            or (isinstance(inner, dict) and ("min" in inner or "max" in inner))
        ):
            return inner
    return value


def _strip_junk(token: str) -> str:
    """Strip OCR artifacts: circled chars (Ⓜ, ⊙), parens, stray punctuation."""
    s = token.strip()
    # Drop leading circled/special chars
    s = re.sub(r"^[⊙ⓄⓂ⓿①②③④⑤⑥⑦⑧⑨☆★\(\[\{]+\s*", "", s)
    # Drop trailing close-brackets
    s = re.sub(r"[\)\]\}]+$", "", s)
    # Strip surrounding quotes
    s = re.sub(r"^['\"]|['\"]$", "", s)
    # Collapse internal whitespace
    s = re.sub(r"\s+", " ", s).strip()
    return s


# ─── accuracy_class ────────────────────────────────────────────────────

# Unicode Roman numerals → ASCII
_UNICODE_ROMAN = {
    "Ⅰ": "I", "Ⅱ": "II", "Ⅲ": "III", "Ⅳ": "IV", "Ⅴ": "V",
    "Ⅵ": "VI", "Ⅶ": "VII", "Ⅷ": "VIII", "Ⅸ": "IX", "Ⅹ": "X",
    # Common OIML-specific form (4 I's, not standard Roman IV)
    "ⅣⅣ": "IIII",
    # Sometimes 4 is written as IIII in OIML context
}

# Letter-system classes (R60 load cells, R51 catchweighers): C, C1, C2, ..., D, D1, ...
_LETTER_DIGIT_RE = re.compile(r"^[A-D](?:[1-9])?$")

# Pure numeric classes (R117/R137 fuel, gas): 0.3, 0.5, 1, 1.5, 2
_NUMERIC_RE = re.compile(r"^\d+(?:\.\d+)?$")

# Token-separator pattern for multi-class declarations
_TOKEN_SPLIT_RE = re.compile(
    r"\s*(?:,|;|\bor\b|\band\b|/|\|)\s*",
    re.IGNORECASE,
)


def normalize_accuracy_class(raw_value: Any) -> list[str]:
    """Normalize an accuracy_class value to a list of canonical class tokens.

    Handles:
      - Single class: "III" → ["III"], "C3" → ["C3"]
      - Multi-class: "III or IIII" → ["III", "IIII"],
                     "['II', 'III']" → ["II", "III"],
                     "II, III, III" → ["II", "III"]  (dedupe)
      - OCR mangling: "11" → "II", "111" → "III", "Ⅲ" → "III"
      - Junk: "or", "and", "Ⓜ", "CD" → filtered out
      - Nested wrappers: {"value": "C3"} → "C3"
    """
    value = _unwrap_nested(raw_value)

    # If it's already a list, normalize each element
    if isinstance(value, list):
        tokens = value
    elif isinstance(value, dict) and ("min" in value or "max" in value):
        # Range — accuracy_class shouldn't be a range; return as-is wrapped
        return [f"min={value.get('min')}, max={value.get('max')}"]
    elif isinstance(value, str):
        # String — possibly a list repr or comma-separated
        s = value.strip()
        # Handle JSON-ish list repr: "['III', 'IIII']"
        if s.startswith("[") and s.endswith("]"):
            inner = s[1:-1]
            tokens = re.findall(r"'([^']+)'|\"([^\"]+)\"|(\w+)", inner)
            tokens = [next(t for t in tup if t) for tup in tokens]
        else:
            tokens = _TOKEN_SPLIT_RE.split(s)
    elif isinstance(value, (int, float)):
        return [_normalize_token(str(value))]
    else:
        return []

    cleaned: list[str] = []
    seen: set[str] = set()
    for t in tokens:
        cleaned_t = _normalize_token(t)
        if cleaned_t and cleaned_t not in seen:
            seen.add(cleaned_t)
            cleaned.append(cleaned_t)
    return cleaned


def _normalize_token(token: Any) -> str | None:
    """Clean one class token. Returns None for pure junk."""
    if not isinstance(token, str):
        token = str(token) if token is not None else ""
    s = _strip_junk(token)
    if not s:
        return None

    # Apply Unicode Roman fixes
    for uni, asc in _UNICODE_ROMAN.items():
        s = s.replace(uni, asc)

    # Pure-junk filters (extraction artifacts)
    if s.lower() in {"or", "and", "/", "|", "n/a", "na", "none", "null"}:
        return None
    # Single-character non-class
    if s in {"Ⓜ", "⊙", "☆", "★"}:
        return None
    # "CD" is a Roman numeral (400) — doesn't belong in OIML accuracy classes; junk
    if s == "CD":
        return None

    # Roman-numeral pattern: 1-6 ASCII I characters
    if re.fullmatch(r"I{1,6}", s.upper()):
        return s.upper()

    # OCR mangled Roman: pure 1's (1, 11, 111, 1111) → Roman
    if re.fullmatch(r"1{1,6}", s):
        return "I" * len(s)

    # Letter+digit class (R60/R51): C3, D1, C, C6
    if _LETTER_DIGIT_RE.match(s):
        return s.upper() if len(s) == 1 else s  # don't uppercase digits

    # Numeric class (R117/R137): 0.5, 1, 1.5, 2
    if _NUMERIC_RE.match(s):
        return s

    # Anything else — return as-is if alphanumeric, junk otherwise
    if re.fullmatch(r"[\w\-]+", s):
        return s
    return None
