# WHATWG server-sent events reference

M11-001 uses the WHATWG HTML Living Standard, section 9.2, Server-sent events:
https://html.spec.whatwg.org/multipage/server-sent-events.html

Retrieved 2026-10-08. HTML snapshot: 76,653 bytes; SHA-256
`885be2a3cddb68fca23b8dd49962fb2c61bbe7e721be7fe72211b1073a900295`.
This identifies the observed living-standard input, not a Git commit or a
promise that the live URL remains byte-identical. No browser source is vendored.

Normative codec rules used:

- UTF-8 decoding with replacement and removal of one initial BOM.
- CR, LF and CRLF; first colon separates field and value, removing at most
  one following space.
- Case-sensitive field names; comments and unknown fields ignored.
- Data lines append LF; dispatch at a blank line removes the final LF.
  Absent data does not dispatch; an empty data field does.
- Empty event type defaults to message. Id containing NUL is ignored.
  Blank-line processing commits the pending last-event-ID buffer, including
  id-only blocks; an id line alone and any block truncated at EOF do not.
- Retry is ASCII digits only. Incomplete events are discarded at EOF.
- HTTP 200 requires event-stream MIME; HTTP 204 stops reconnection.

Intentional Wirestack policy differences: reconnection is opt-in, GET-only,
count/duration/backoff bounded, and does not follow redirects. No browser
EventSource object, CORS policy or browser-origin credential behavior is
provided. Codec line/block/field/cursor/no-progress limits and retry clamping
are explicit resource limits. Last-Event-ID is not application acknowledgement.

Qualified native inputs retain the existing Linux SDK/provider references:
[SDK 1.1.3 qualification](m9-002-option-sdk.json) and
[toolchain/documentation identity](m7-033-ci-toolchain.json). SDK 1.1.3's archive
does not publish a compiler source commit; its exact archive hash is recorded
rather than invented. M11-001 records observed compiler versions and installed
provider identity in its evidence and does not modify external repositories.
