"""Namespace boundaries and URL evidence redaction for the installed WebSocket gate."""
import unittest

from tools import m11_003_native_websocket as websocket


class PublicImportsTest(unittest.TestCase):
    def test_private_namespaces_are_rejected_with_symbols_or_aliases(self):
        for entry in ("wirestack.internal.http1.*", "wirestack.internal as private", "std.net.*", "std.net as network", "std.net.TcpSocket"):
            with self.subTest(entry=entry):
                with self.assertRaises(RuntimeError):
                    websocket.public_imports(f"import {entry}\n")

    def test_similar_component_names_are_not_private_namespaces(self):
        imports = ["wirestack.internalized.Value", "mystd.net.Socket", "example.std.net.Value"]
        self.assertEqual(websocket.public_imports("\n".join(f"import {entry}" for entry in imports)), imports)


class EvidenceRedactionTest(unittest.TestCase):
    def test_every_url_component_is_removed_before_evidence_storage(self):
        cases = (
            "https://user:secret@example.test/std.net/path",
            "https://user:secret@example.test/path?module=std.net&token=secret",
            "https://user:secret@example.test/path#std.net/secret",
            "https://user:secret@example.test/path?token=secret#std.net",
            "wss://user%40name:p%40ss@[2001:db8::2]:8443/echo%2Fpath?q=%25#secret",
            "ws://user@example.test:80/path",
            "ws://user:secret@extra@example.test/path",
            "https://example.test:443/safe%2Fpath",
            "ftp://example.test/private",
        )
        for url in cases:
            with self.subTest(url=url):
                output = websocket.redact_output(f"request failed: {url} failed", [])
                self.assertEqual(output, "request failed: <redacted-url> failed")
                self.assertNotIn(url, output)

    def test_malformed_authority_fails_closed(self):
        for url in ("https://user:secret@[broken/path", "https://user:secret@example.test:invalid/path"):
            with self.subTest(url=url):
                self.assertEqual(websocket.redact_output(url, []), "<redacted-url>")

    def test_path_and_fixture_address_redaction_still_applies(self):
        self.assertEqual(websocket.redact_output("/workspace/file ws://user:secret@127.0.0.1:80/path",
            [("/workspace", "<repo>")]), "<repo>/file <redacted-url>")
