from __future__ import annotations

import unittest

from tools import m9_001_native_capabilities as native


class NativeCapabilitiesTest(unittest.TestCase):
    def capability_line(self, class_name: str, instance: str) -> str:
        expected = native.EXPECTED_CAPABILITIES[class_name]
        flags = " ".join("true" if expected[field] else "false" for field in native.CAPABILITY_FIELDS)
        return f"CAP {class_name} {instance} {flags}"

    def complete_lines(self) -> list[str]:
        return [
            self.capability_line("TcpStream", "accepted"),
            self.capability_line("TcpStream", "outgoing"),
            self.capability_line("TcpListener", "listener"),
            self.capability_line("UdpSocket", "ipv4"),
            self.capability_line("UdpSocket", "ipv6"),
            self.capability_line("UnixStream", "accepted"),
            self.capability_line("UnixStream", "outgoing"),
            self.capability_line("UnixListener", "listener"),
            self.capability_line("UnixDatagramSocket", "datagram"),
        ]

    def test_duplicate_observation_cannot_replace_a_required_instance(self) -> None:
        lines = self.complete_lines()
        lines.append(lines[0])
        with self.assertRaises(RuntimeError):
            native.parse_capability_observations(lines)

    def test_non_boolean_flag_is_not_coerced_to_false(self) -> None:
        lines = self.complete_lines()
        lines[0] = lines[0].replace("false", "unknown", 1)
        with self.assertRaises(RuntimeError):
            native.parse_capability_observations(lines)

    def test_cross_instance_difference_is_rejected(self) -> None:
        lines = self.complete_lines()
        parts = lines[4].split()
        half_close = 3 + native.CAPABILITY_FIELDS.index("halfClose")
        parts[half_close] = "true"
        lines[4] = " ".join(parts)
        with self.assertRaises(RuntimeError):
            native.parse_capability_observations(lines)



    def test_normalization_removes_checkout_sdk_home_and_scratch_paths(self) -> None:
        raw = f"{native.ROOT}/src {native.ROOT.parent}/peer /tmp/private/file {native.Path.home()}/token"
        normalized = native.normalize_text(raw, ((str(native.ROOT.parent / "peer"), "<peer>"),))
        self.assertNotIn(str(native.ROOT), normalized)
        self.assertNotIn(str(native.Path.home()), normalized)
        self.assertNotIn("/tmp/private", normalized)
        self.assertIn("<repo>/src", normalized)
        self.assertIn("<peer>", normalized)


if __name__ == "__main__":
    unittest.main()
