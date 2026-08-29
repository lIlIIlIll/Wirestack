# Independent reviewer instructions

Review the exact package identified by `evidence-index.json`. Record the package
SHA-256 before inspecting source. If the digest changes, stop and request a new
review target.

The review must cover supply chain, certificate and reference identity, private
keys, TLS protocol configuration, cancellation and close races, DNS and proxy
routing, HTTP/1.1 smuggling, HTTP/2 and HPACK state, resource bounds, connection
pool isolation, sensitive-data handling, native C ABI, Linux platform behavior,
and release evidence integrity.

Use source review, negative tests, boundary analysis, lifecycle and concurrency
analysis, native provider inspection, and targeted reproduction where they fit.
Do not list a method that was not performed. Do not place private keys,
credentials, cookies, session secrets, traffic secrets, or captured request
bodies in the report.

For each finding, provide a stable ID, severity, affected location, reproduction
steps, impact, evidence, and disposition. A Fixed finding must name its fix and
an executed regression command. Open High or Critical findings block release.

The report must state reviewer identity, review dates, independence from the
implementation, review mode, and every conflict. `External` is used for a human
or organization outside the implementation process. `ProcessIsolatedAgent` is
allowed only when the agent inherits no implementation context, reviews a clean
detached snapshot, does not implement or modify the reviewed production code,
and discloses its relationship to the repository owner and implementation
orchestrator. The implementation agent cannot review its own changes under
either mode. Compatibility with experimental pre-1.0 APIs is not part of the
review or release decision.
