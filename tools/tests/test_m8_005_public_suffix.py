import unittest

from third_party.public_suffix.generate import parse_snapshot


class PublicSuffixGenerationTest(unittest.TestCase):
    def snapshot(self, rules: str) -> bytes:
        return (
            "// VERSION: fixture\n// COMMIT: " + "0" * 40 + "\n" + rules
        ).encode("utf-8")

    def test_punycode_preserves_sharp_s_instead_of_mapping_it_to_ss(self) -> None:
        exact = parse_snapshot(self.snapshot("FAß.test\n"))[2]
        self.assertEqual(["xn--fa-hia.test"], exact)

    def test_rule_operators_and_inline_comments_preserve_matching_domains(self) -> None:
        rules = "foo.test // comment\n*.bar.test\n!safe.bar.test\n"
        self.assertEqual(
            (["foo.test"], ["bar.test"], ["safe.bar.test"]),
            parse_snapshot(self.snapshot(rules))[2:],
        )

    def test_invalid_labels_cannot_enter_generated_string_literals(self) -> None:
        with self.assertRaisesRegex(ValueError, "invalid DNS label"):
            parse_snapshot(self.snapshot('bad".test\n'))
