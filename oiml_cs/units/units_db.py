"""UnitsDB helper — loads unitsdb YAML and provides canonical unit lookup.

Source: ~/src/unitsml/unitsdb/units.yaml (NIST/OIML units database v2.0.0)

Public API:
  - UnitsDb.unit_for_symbol(symbol: str) -> UnitEntry | None
  - UnitsDb.unit_for_id(unit_id: str) -> UnitEntry | None
  - UnitEntry: {id, short, names, symbols, quantity_references}
"""
from __future__ import annotations

from dataclasses import dataclass, field
from functools import cached_property
from pathlib import Path
from typing import Any

import yaml

DEFAULT_UNITSDB_PATH = Path.home() / "src/unitsml/unitsdb/units.yaml"


@dataclass(frozen=True)
class UnitEntry:
    unit_id: str                      # canonical unitsml ID, e.g. "u:degree_Celsius"
    nist_id: str | None               # NISTu1, NISTu14, ...
    short: str                        # short name, e.g. "degree Celsius"
    names: dict[str, str]             # lang → name, e.g. {"en": "volt"}
    symbols: dict[str, str]           # form → symbol, e.g. {"unicode": "°C", "ascii": "degC"}
    quantity_ids: list[str]           # quantity IDs this unit measures

    @property
    def unicode_symbol(self) -> str | None:
        return self.symbols.get("unicode")

    @property
    def ascii_symbol(self) -> str | None:
        return self.symbols.get("ascii")


# Map of common symbol strings (as they appear in OIML cert text) → unitsml ID.
# Extended at runtime by walking unitsdb.
_SYMBOL_ALIASES = {
    "°C": "u:degree_Celsius",
    "℃": "u:degree_Celsius",
    "degC": "u:degree_Celsius",
    "°C/h": "u:degree_Celsius_per_hour",
    "K": "u:kelvin",
    "kg": "u:kilogram",
    "g": "u:gram",
    "t": "u:metric_ton",            # metric ton (NOT short_ton)
    "mg": "u:milligram",
    "m": "u:meter",
    "mm": "u:millimeter",
    "km": "u:kilometer",
    "cm": "u:centimeter",
    "m/s": "u:meter_per_second",
    "km/h": "u:kilometer_per_hour",
    "m³": "u:cubic_meter",
    "m3": "u:cubic_meter",
    "L": "u:liter",
    "l": "u:liter",
    "L/min": None,             # not in unitsdb directly; keep raw
    "m³/h": None,
    "m3/h": None,
    "V": "u:volt",
    "V AC": "u:volt",
    "VAC": "u:volt",
    "V DC": "u:volt",
    "VDC": "u:volt",
    "mV/V": "u:millivolt_per_volt",
    "Hz": "u:hertz",
    "A": "u:ampere",
    "mA": "u:milliampere",
    "Ω": "u:ohm",
    "ohm": "u:ohm",
    "Pa": "u:pascal",
    "kPa": "u:kilopascal",
    "MPa": "u:megapascal",
    "bar": "u:bar",
    "mbar": "u:millibar",
    "W": "u:watt",
    "kW": "u:kilowatt",
    "Wh": "u:watt_hour",
    "kWh": "u:kilowatt_hour",
    "s": "u:second_time",
    "min": "u:minute",
    "h": "u:hour",
    "%": "u:percent",
    "ppm": "u:parts_per_million",
    "ppb": "u:parts_per_billion",
    "N": "u:newton",
    "Nm": "u:newton_meter",
    "rad": "u:radian",
    "°": "u:degree",
    "cd": "u:candela",
    "lm": "u:lumen",
    "lx": "u:lux",
}


class UnitsDb:
    """Lazy-loading unitsdb lookup."""

    def __init__(self, unitsdb_path: Path = DEFAULT_UNITSDB_PATH):
        self._path = unitsdb_path
        self._by_id: dict[str, UnitEntry] | None = None
        self._by_symbol: dict[str, UnitEntry] | None = None

    @cached_property
    def _loaded(self) -> dict:
        if not self._path.exists():
            raise FileNotFoundError(f"unitsdb not found at {self._path}")
        return yaml.safe_load(self._path.read_text())

    def _load(self) -> None:
        if self._by_id is not None:
            return
        self._by_id = {}
        self._by_symbol = {}
        for raw in self._loaded.get("units", []):
            ids = {i.get("type"): i.get("id") for i in raw.get("identifiers", [])}
            unit_id = ids.get("unitsml") or ids.get("nist") or ""
            nist_id = ids.get("nist")
            short = raw.get("short", "")
            names = {n.get("lang"): n.get("value") for n in raw.get("names", [])}
            symbols = {}
            for s in raw.get("symbols", []):
                for k in ("unicode", "ascii", "html", "latex", "mathml", "id"):
                    if k in s:
                        symbols[k] = s[k]
            qty_refs = [q.get("id") for q in raw.get("quantity_references", [])]
            entry = UnitEntry(
                unit_id=unit_id,
                nist_id=nist_id,
                short=short,
                names=names,
                symbols=symbols,
                quantity_ids=qty_refs,
            )
            if unit_id:
                self._by_id[unit_id] = entry
            if nist_id:
                self._by_id[nist_id] = entry
            # Index every symbol form
            for form in ("unicode", "ascii", "id"):
                if form in symbols:
                    self._by_symbol.setdefault(symbols[form], entry)
            # Index by short name
            if short:
                self._by_symbol.setdefault(short, entry)

    def unit_for_symbol(self, symbol: str) -> UnitEntry | None:
        self._load()
        assert self._by_symbol is not None
        # Try alias table first (handles OIML-specific forms like "V AC", "m³/h")
        if symbol in _SYMBOL_ALIASES:
            entry = self._by_id.get(_SYMBOL_ALIASES[symbol])
            if entry:
                return entry
        return self._by_symbol.get(symbol)

    def unit_for_id(self, unit_id: str) -> UnitEntry | None:
        self._load()
        assert self._by_id is not None
        return self._by_id.get(unit_id)
