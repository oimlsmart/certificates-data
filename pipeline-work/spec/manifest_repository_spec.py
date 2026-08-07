"""Specs for ManifestRepository."""
import pytest

from oiml_cs.domain import EditionYear, RNumber
from oiml_cs.infrastructure.manifest_repository import ManifestRepository


@pytest.fixture(scope="module")
def repo(manifest_path):
    return ManifestRepository(manifest_path)


class TestManifestRepository:
    def test_loads_all_certificates(self, repo):
        certs = repo.all_certificates
        assert len(certs) == 6476

    def test_recommendations_returns_sorted_distinct(self, repo):
        recs = repo.recommendations()
        rnums = [r.r_number for r in recs]
        assert rnums == sorted(rnums)
        assert len(rnums) == len(set(rnums))
        assert RNumber(76) in rnums

    def test_certificates_for_r76_2006(self, repo):
        certs = repo.certificates_for(RNumber(76), EditionYear(2006))
        assert len(certs) > 1000
        for c in certs:
            assert c.recommendation == RNumber(76)
            assert c.edition_year == EditionYear(2006)

    def test_latest_edition_of_r76(self, repo):
        assert repo.latest_edition(RNumber(76)) == EditionYear(2006)

    def test_latest_edition_of_r60(self, repo):
        assert repo.latest_edition(RNumber(60)) == EditionYear(2021)

    def test_editions_of_r76_returns_both(self, repo):
        eds = repo.editions_of(RNumber(76))
        assert eds == [EditionYear(1992), EditionYear(2006)]

    def test_latest_edition_returns_none_for_unknown(self, repo):
        assert repo.latest_edition(RNumber(999)) is None

    def test_caches_between_calls(self, repo):
        """all_certificates is read once, returned twice."""
        first = repo.all_certificates
        second = repo.all_certificates
        assert first is second
