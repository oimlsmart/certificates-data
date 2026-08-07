"""Specs for domain value objects: RNumber, EditionYear, Issuer."""
import pytest

from oiml_cs.domain import Certificate, Edition, EditionYear, Issuer, RNumber, Recommendation


class TestRNumber:
    def test_parse_strips_leading_zeros(self):
        assert RNumber.parse("R076") == RNumber(76)
        assert RNumber.parse("R76") == RNumber(76)
        assert RNumber.parse("r21") == RNumber(21)

    def test_str_is_canonical_no_leading_zeros(self):
        assert str(RNumber(76)) == "R76"
        assert str(RNumber(0)) == "R0"
        assert str(RNumber(105)) == "R105"

    def test_ordering_by_value(self):
        assert RNumber(21) < RNumber(76)
        assert RNumber(76) == RNumber.parse("R076")
        assert sorted([RNumber(76), RNumber(21), RNumber(60)]) == [RNumber(21), RNumber(60), RNumber(76)]

    def test_rejects_negative(self):
        with pytest.raises(ValueError):
            RNumber(-1)

    def test_rejects_unparseable(self):
        with pytest.raises(ValueError):
            RNumber.parse("XYZ")
        with pytest.raises(ValueError):
            RNumber.parse("")


class TestEditionYear:
    def test_str_is_value(self):
        assert str(EditionYear(2006)) == "2006"

    def test_rejects_out_of_range(self):
        with pytest.raises(ValueError):
            EditionYear(1800)
        with pytest.raises(ValueError):
            EditionYear(2200)


class TestIssuer:
    def test_parse_uppercase(self):
        assert Issuer.parse("nl1") == Issuer("NL1")

    def test_country_code_extracts_letters(self):
        assert Issuer("NL1").country_code == "NL"
        assert Issuer("GB1").country_code == "GB"
        assert Issuer("DK3").country_code == "DK"

    def test_rejects_invalid_format(self):
        with pytest.raises(ValueError):
            Issuer("Netherlands1")
        with pytest.raises(ValueError):
            Issuer("1NL")


class TestEdition:
    def test_path_segment(self):
        ed = Edition(RNumber(76), EditionYear(2006))
        assert ed.path_segment() == "R76/2006"

    def test_str(self):
        ed = Edition(RNumber(60), EditionYear(2021))
        assert str(ed) == "R60/2021"

    def test_rejects_wrong_types(self):
        with pytest.raises(TypeError):
            Edition("R76", EditionYear(2006))  # type: ignore[arg-type]


class TestRecommendation:
    def test_rejects_wrong_types(self):
        with pytest.raises(TypeError):
            Recommendation(76)  # type: ignore[arg-type]


class TestCertificateFromManifest:
    def test_parses_file_name_into_value_objects(self):
        row = {
            "id": 4440,
            "num": "R076/2006-BG1-2013.17 Rev. 1",
            "fileName": "r076-2006-bg1-2013-17-rev1.pdf",
            "status": "Valid",
            "applicant": "CAS Corporation",
            "issuingYear": "2017",
            "local_path": "certificates/R76/2006/r076-2006-bg1-2013-17-rev1.pdf",
        }
        cert = Certificate.from_manifest_row(row)
        assert cert.id == 4440
        assert cert.recommendation == RNumber(76)
        assert cert.edition_year == EditionYear(2006)
        assert cert.issuer == Issuer("BG1")
        assert cert.cert_year == 2013
        assert cert.stem == "r076-2006-bg1-2013-17-rev1"

    def test_handles_missing_file_name(self):
        row = {"id": 1, "num": "R031/1995-FR1-1999.01", "fileName": None, "status": "Valid"}
        cert = Certificate.from_manifest_row(row)
        assert cert.file_name is None
        assert cert.recommendation is None
        assert cert.edition_year is None
        assert cert.local_pdf_path is None
        assert cert.stem == "cert-1"

    def test_stem_handles_no_extension(self):
        row = {"id": 2, "num": "X", "fileName": "no-ext", "status": "Valid"}
        cert = Certificate.from_manifest_row(row)
        assert cert.stem == "no-ext"
