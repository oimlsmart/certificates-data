"""Specs for StratifiedSampler."""
from oiml_cs.domain import Certificate, Issuer, RNumber, EditionYear
from oiml_cs.sampling.stratified_sampler import StratifiedSampler


def _make_cert(id: int, issuer: str, year: int) -> Certificate:
    return Certificate(
        id=id,
        num=f"R99/2008-{issuer}-{year}.{id:02d}",
        file_name=f"r099-2008-{issuer.lower()}-{year}-{id:02d}.pdf",
        status="Valid",
        issuer=Issuer(issuer),
        cert_year=year,
    )


class TestStratifiedSampler:
    def test_returns_all_when_fewer_than_sample_size(self):
        certs = [_make_cert(i, "NL1", 2010 + i) for i in range(5)]
        sampler = StratifiedSampler(sample_size=100)
        result = sampler.sample(certs)
        assert len(result) == 5

    def test_caps_at_sample_size(self):
        certs = [_make_cert(i, "NL1", 2010 + (i % 10)) for i in range(200)]
        sampler = StratifiedSampler(sample_size=50)
        result = sampler.sample(certs)
        assert len(result) == 50

    def test_represents_all_issuers(self):
        """With 3 issuers, all 3 must appear in the sample."""
        certs = []
        for i in range(30):
            issuer = ["NL1", "GB1", "DE1"][i % 3]
            certs.append(_make_cert(i, issuer, 2010 + (i % 5)))
        sampler = StratifiedSampler(sample_size=10)
        result = sampler.sample(certs)
        issuers_in_sample = {c.issuer.code for c in result}
        assert issuers_in_sample == {"NL1", "GB1", "DE1"}

    def test_is_deterministic(self):
        """Same input → same output."""
        certs = [_make_cert(i, "NL1", 2010 + (i % 10)) for i in range(200)]
        s1 = StratifiedSampler(sample_size=30).sample(certs)
        s2 = StratifiedSampler(sample_size=30).sample(certs)
        assert [c.id for c in s1] == [c.id for c in s2]

    def test_handles_unknown_issuer(self):
        """Certs with issuer=None go into _unknown bucket."""
        cert = Certificate(id=1, num="x", file_name="x.pdf", status="V", issuer=None, cert_year=2020)
        sampler = StratifiedSampler(sample_size=10)
        result = sampler.sample([cert])
        assert len(result) == 1
