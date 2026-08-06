"""StratifiedSampler: distribute sample_size across issuers, then years.

Algorithm:
  1. Group certs by issuer.
  2. Distribute sample_size proportionally; floor of 1 per represented issuer.
  3. Within each issuer, evenly-space certs by cert_year (not random — for
     determinism).
"""
from __future__ import annotations

import collections
from typing import Iterable

from oiml_cs.domain.certificate import Certificate


class StratifiedSampler:
    def __init__(self, sample_size: int = 100, seed: int = 42):
        self._sample_size = sample_size
        self._seed = seed

    def sample(self, certs: Iterable[Certificate]) -> list[Certificate]:
        pool = list(certs)
        if len(pool) <= self._sample_size:
            return sorted(pool, key=lambda c: c.num)

        by_issuer: dict[str, list[Certificate]] = collections.defaultdict(list)
        for c in pool:
            iss = str(c.issuer) if c.issuer else "_unknown"
            by_issuer[iss].append(c)

        # Proportional quota per issuer (min 1)
        total = sum(len(v) for v in by_issuer.values())
        quota = {iss: max(1, round(self._sample_size * len(v) / total)) for iss, v in by_issuer.items()}
        while sum(quota.values()) > self._sample_size:
            big = max(quota, key=lambda k: quota[k])
            quota[big] -= 1
        while sum(quota.values()) < self._sample_size:
            big = max(quota, key=lambda k: len(by_issuer[k]))
            if quota[big] < len(by_issuer[big]):
                quota[big] += 1
            else:
                break

        out: list[Certificate] = []
        for iss, n in quota.items():
            pool_issuer = sorted(by_issuer[iss], key=lambda c: c.cert_year or 0)
            if n >= len(pool_issuer):
                chosen = pool_issuer
            else:
                idx = [int(i * (len(pool_issuer) - 1) / max(1, n - 1)) for i in range(n)]
                chosen = [pool_issuer[i] for i in idx]
            out.extend(chosen)
        return sorted(out, key=lambda c: c.num)
