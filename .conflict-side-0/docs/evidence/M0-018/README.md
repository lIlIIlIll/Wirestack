# M0-018 evidence — Wirestack threat model

## Status

- Task: **COMPLETE**
- Threat register: **18 threats across 14 required domains**
- Control catalogue: **14 controls**
- Production Transport/TLS/HTTP code changed: **NO**
- Final TLS provider selected: **NO**

## Deliverables

- [`docs/security/threat-model.md`](../../security/threat-model.md)
- [`docs/security/threat-model.json`](../../security/threat-model.json)
- [`tools/validate_threat_model.py`](../../../tools/validate_threat_model.py)
- [`tools/tests/test_validate_threat_model.py`](../../../tools/tests/test_validate_threat_model.py)
- [Threat Model CI](../../../.github/workflows/threat-model.yml)

The register covers supply chain, certificate/reference identity, key boundaries,
TLS protocol, transport lifecycle, cancellation races, DNS/routing, HTTP parser
smuggling, HTTP/2/resource exhaustion, pool isolation, secret logging, C ABI,
platform adapters and release evidence.

Every threat maps to existing Wirestack backlog tasks. Every HIGH/CRITICAL threat
has `release_blocker=true`; the validator rejects an `ACCEPTED` disposition or a
missing release blocker. Missing domains, controls, backlog tasks, cross-references
and residual-risk statements also fail closed.

## Verification

```text
python3 tools/validate_threat_model.py
Wirestack threat model: PASS (18 threats, 14 controls)

python3 -m unittest discover -s tools/tests -p 'test_validate_threat_model.py' -v
Ran 10 tests
OK

python3 -m py_compile tools/validate_threat_model.py
exit 0
```

The threat model is a design and release-control baseline. M0-016 still performs
native provider PoCs, and M0-020 still owns final provider selection. Unavailable
platforms and unexecuted security tests remain blockers rather than PASS.
