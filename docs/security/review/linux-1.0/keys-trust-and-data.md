# Keys, trust, and sensitive data

The default TLS policy verifies the certificate chain and reference identity.
There is no public trust-all mode. Custom roots and client identities are
explicit, scoped configuration. TLS 1.0 and TLS 1.1 are disabled.

Private keys, credentials, session secrets, traffic secrets, authorization
values, cookies, and captured request bodies must not appear in logs, reports,
or this review package. Test certificates and keys remain synthetic fixtures;
the evidence index does not embed their bytes. Key logging is restricted to an
explicit test or debug workflow and is not enabled in release artifacts.

Errors retain category, phase, stable code, retryability, native code when
available, endpoints, and cause, while excluding sensitive payloads.

