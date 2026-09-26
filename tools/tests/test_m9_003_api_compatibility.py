from __future__ import annotations

import unittest

from tools.m9_003_api_compatibility import compare_inventories


def inventory(declarations: list[dict]) -> dict:
    return {"declarations": declarations}


def declaration(name: str, members: list[dict] | None = None, signature: str | None = None) -> dict:
    return {
        "package": "wirestack.net",
        "kind": "class",
        "name": name,
        "signature": signature or f"public class {name}",
        "members": members or [],
    }


def member(name: str, signature: str | None = None) -> dict:
    return {"kind": "func", "name": name, "signature": signature or f"public func {name}(): Unit"}


class M9003ApiCompatibilityTest(unittest.TestCase):
    def test_new_methods_are_additive_and_preserve_existing_signatures(self) -> None:
        previous = inventory([declaration("UdpSocket", [member("send"), member("receive")])])
        current = inventory([declaration("UdpSocket", [
            member("send"), member("receive"), member("disconnect"),
        ])])

        result = compare_inventories(previous, current)

        self.assertTrue(result["source_compatible"])
        self.assertEqual([item["name"] for item in result["added_members"]], ["disconnect"])
        self.assertEqual(result["removed_members"], [])

    def test_removed_method_is_incompatible(self) -> None:
        previous = inventory([declaration("UdpSocket", [member("send"), member("receive")])])
        current = inventory([declaration("UdpSocket", [member("send")])])

        result = compare_inventories(previous, current)

        self.assertFalse(result["source_compatible"])
        self.assertEqual([item["name"] for item in result["removed_members"]], ["receive"])

    def test_changed_signature_is_incompatible(self) -> None:
        previous = inventory([declaration("UdpSocket", [member("send", "public func send(data: Bytes): Unit")])])
        current = inventory([declaration("UdpSocket", [member("send", "public func send(data: ByteSpan): Unit")])])

        result = compare_inventories(previous, current)

        self.assertFalse(result["source_compatible"])
        self.assertEqual(len(result["removed_members"]), 1)
        self.assertEqual(len(result["added_members"]), 1)

    def test_duplicate_declarations_fail_closed(self) -> None:
        value = declaration("UdpSocket")

        with self.assertRaisesRegex(ValueError, "duplicate API declaration"):
            compare_inventories(inventory([value, value]), inventory([value]))


if __name__ == "__main__":
    unittest.main()
