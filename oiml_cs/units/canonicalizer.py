"""Canonicalizer: maps extracted characteristic labels to canonical names.

Loads synonym maps from `schema/_modules/*.yaml` (thematic modules) and
provides canonical lookup. The CORE schema (`_core.yaml`) declares only
document-level metadata — no characteristics live there.

Public API:
  - canonical_for(raw_label) -> str
  - shared_module_labels() -> set[str]  (across all modules)
  - module_for(label) -> str | None  (which module declares this label)
"""
from __future__ import annotations

import re
from functools import cached_property
from pathlib import Path

import yaml

DEFAULT_MODULES_DIR = Path(__file__).resolve().parent.parent.parent / "schema" / "_modules"


class LabelCanonicalizer:
    """Map any raw extracted label to its canonical form.

    Looks up across all module files in `schema/_modules/`. Returns the
    label unchanged if no module matches (R-specific label).
    """

    def __init__(self, modules_dir: Path = DEFAULT_MODULES_DIR):
        self._modules_dir = modules_dir

    @cached_property
    def _modules(self) -> dict[str, dict]:
        """module_name → {characteristics: {label: spec}}."""
        modules: dict[str, dict] = {}
        for f in sorted(self._modules_dir.glob("*.yaml")):
            modules[f.stem] = yaml.safe_load(f.read_text()) or {}
        return modules

    @cached_property
    def _synonym_to_canonical(self) -> dict[str, str]:
        out: dict[str, str] = {}
        for module_name, mod in self._modules.items():
            for canonical, spec in (mod.get("characteristics") or {}).items():
                out[canonical] = canonical
                for syn in spec.get("synonyms", []) or []:
                    out[syn] = canonical
        return out

    @cached_property
    def _label_to_module(self) -> dict[str, str]:
        out: dict[str, str] = {}
        for module_name, mod in self._modules.items():
            for canonical in (mod.get("characteristics") or {}).keys():
                out[canonical] = module_name
        return out

    def canonical_for(self, raw_label: str) -> str:
        if not raw_label:
            return raw_label
        norm = self._normalize(raw_label)
        return self._synonym_to_canonical.get(norm, norm)

    def module_for(self, label: str) -> str | None:
        canonical = self.canonical_for(label)
        return self._label_to_module.get(canonical)

    def shared_module_labels(self) -> set[str]:
        return set(self._label_to_module.keys())

    def is_module_label(self, label: str) -> bool:
        return self.canonical_for(label) in self._label_to_module

    @staticmethod
    def _normalize(label: str) -> str:
        s = label.strip().lower()
        s = re.sub(r"[\s\-]+", "_", s)
        s = re.sub(r"[^a-z0-9_]", "", s)
        s = re.sub(r"_+", "_", s).strip("_")
        return s
