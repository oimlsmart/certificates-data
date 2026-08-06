"""CertificateYamlSerializer (v2): handles the layered ParsedCertificate.

Replaces the regex-parsed structure with the layered schema from
schema/_common_certificate_schema.yaml.
"""
from __future__ import annotations

import yaml

from oiml_cs.domain.certificate import Certificate
from oiml_cs.extraction.parsed_certificate import ParsedCertificate


class CertificateYamlSerializer:
    def serialize(self, certificate: Certificate, parsed: ParsedCertificate) -> str:
        payload = {
            "_meta": self._meta(certificate, parsed),
            **parsed.to_dict(),
        }
        return yaml.safe_dump(
            payload,
            allow_unicode=True,
            sort_keys=False,
            default_flow_style=False,
            width=100,
        )

    @staticmethod
    def _meta(c: Certificate, parsed: ParsedCertificate) -> dict:
        return {
            "cert_id": c.id,
            "num": c.num,
            "applicant": c.applicant,
            "issuing_year": c.issuing_year,
            "status": c.status,
            "issuer": str(c.issuer) if c.issuer else None,
            "recommendation": str(c.recommendation) if c.recommendation else None,
            "edition_year": c.edition_year.value if c.edition_year else None,
            "extraction_method": "glm-extract",
            "source_pdf": c.local_pdf_path,
        }
