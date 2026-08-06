"""Schema, Section, Field: value objects produced by the synthesizer."""
from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class Field:
    name: str
    type: str
    present_count: int
    total_count: int
    distinct_count: int | None = None
    element_types: dict | None = None
    enum: list | None = None
    examples: list = field(default_factory=list)

    @property
    def fill_rate(self) -> float:
        return round(self.present_count / self.total_count, 3) if self.total_count else 0.0


@dataclass
class Section:
    name: str
    fields: dict[str, Field] = field(default_factory=dict)


@dataclass
class Schema:
    recommendation: str
    edition: int | None
    sample_size: int
    sections: dict[str, Section] = field(default_factory=dict)
    sample_size_note: str | None = None
