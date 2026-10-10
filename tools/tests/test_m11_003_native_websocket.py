"""Public consumer namespace boundaries for the installed WebSocket gate."""
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

