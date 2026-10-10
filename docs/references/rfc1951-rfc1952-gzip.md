# Gzip format references for M11-002

These specifications define the original Wirestack Cangjie decoder. No reference
implementation is vendored, linked or loaded. Fixtures are checked against zlib
outside production; neither installed consumer invokes a compressor.

| Reference | Edition | Retrieved source | SHA-256 of downloaded bytes |
|---|---|---|---|
| RFC 1951, DEFLATE Compressed Data Format Specification | May 1996 | https://www.rfc-editor.org/rfc/rfc1951.txt | 5ebf4b5b7fe1c3a0c0ab9aa3ac8c0f3853a7dc484905e76e03b0b0f301350009 |
| RFC 1952, GZIP file format specification | May 1996 | https://www.rfc-editor.org/rfc/rfc1952.txt | 164ef0897b4cbec63abf1b57f069f3599bd0fb7c72c2a4dee21bd7e03ec9af67 |

Wirestack's explicit policy is stricter than permissive file readers: default one
member; bounded opt-in concatenation; no trailing non-member bytes or zero padding.
CRC32, optional header CRC and ISIZE are verified. Output remains provisional until
all members and physical wire EOF validate. HTTP coding lists are a separate layer:
only a single gzip coding is decoded, not stacked codings.

The optional package uses the repository Apache-2.0 license. It has no new external
package, native compression archive or shared-library dependency. Existing TLS,
resolver and HTTP file components retain their separately recorded provenance.
