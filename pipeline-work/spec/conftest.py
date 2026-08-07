"""Shared pytest fixtures."""
from __future__ import annotations

from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture(scope="session")
def repo_root() -> Path:
    return ROOT


@pytest.fixture(scope="session")
def manifest_path(repo_root: Path) -> Path:
    return repo_root / "manifest.jsonl"


@pytest.fixture(scope="session")
def r76_md_dir(repo_root: Path) -> Path:
    return repo_root / "ocr_md" / "R76" / "2006"
