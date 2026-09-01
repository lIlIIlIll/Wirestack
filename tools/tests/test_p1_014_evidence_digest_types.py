from __future__ import annotations

import tempfile
import unittest
import platform
import subprocess
from pathlib import Path
from unittest import mock

from tools.evidence_digest import (
    ARTIFACT_BYTE_DOMAIN,
    TEXT_EVIDENCE_DOMAIN,
    ArtifactByteDigest,
    DigestError,
    TextEvidenceDigest,
    artifact_byte_digest_bytes,
    artifact_byte_sha256_equal,
    atomic_json,
    crlf_report,
    digest_inventory,
    parse_artifact_digest,
    parse_text_digest,
    text_evidence_digest_bytes,
    text_evidence_inventory_sha256,
    text_evidence_sha256_equal,
)


class EvidenceDigestTypeTests(unittest.TestCase):
    ROOT = Path(__file__).resolve().parents[2]

    def test_line_endings_share_text_digest_but_not_byte_digest(self) -> None:
        variants = (b"alpha\nbeta\n", b"alpha\r\nbeta\r\n", b"alpha\rbeta\r")
        text = [text_evidence_digest_bytes(value) for value in variants]
        raw = [artifact_byte_digest_bytes(value) for value in variants]
        self.assertEqual(1, len({item.sha256 for item in text}))
        self.assertEqual(3, len({item.sha256 for item in raw}))
        self.assertEqual(TEXT_EVIDENCE_DOMAIN, text[0].to_json()["domain"])
        self.assertEqual(ARTIFACT_BYTE_DOMAIN, raw[0].to_json()["domain"])

    def test_text_inventory_rejects_nul_framing_ambiguity(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-p1-014-frame-") as directory:
            root = Path(directory)
            (root / "a").write_bytes(b"x\0b\0y")
            with self.assertRaises(DigestError) as caught:
                text_evidence_inventory_sha256(root, [root / "a"])
            self.assertEqual("TEXT_NUL", caught.exception.code)

    def test_invalid_utf8_fails_without_byte_fallback(self) -> None:
        with self.assertRaises(DigestError) as caught:
            text_evidence_digest_bytes(b"valid\n\xff")
        self.assertEqual("TEXT_UTF8", caught.exception.code)

    def test_digest_types_and_serialized_domains_are_not_interchangeable(self) -> None:
        text = text_evidence_digest_bytes(b"same\n")
        artifact = ArtifactByteDigest(text.sha256)
        self.assertNotEqual(text, artifact)
        self.assertIsInstance(parse_text_digest(text.to_json()), TextEvidenceDigest)
        self.assertIsInstance(parse_artifact_digest(artifact.to_json()), ArtifactByteDigest)
        with self.assertRaises(DigestError) as text_error:
            parse_text_digest(artifact.to_json())
        self.assertEqual("DIGEST_DOMAIN", text_error.exception.code)
        with self.assertRaises(DigestError) as byte_error:
            parse_artifact_digest(text.to_json())
        self.assertEqual("DIGEST_DOMAIN", byte_error.exception.code)

    def test_digest_equality_requires_both_serialized_domains(self) -> None:
        text = text_evidence_digest_bytes(b"same\n")
        artifact = artifact_byte_digest_bytes(b"same\n")
        self.assertTrue(text_evidence_sha256_equal(text.to_json(), text.to_json()))
        self.assertTrue(artifact_byte_sha256_equal(artifact.to_json(), artifact.to_json()))
        self.assertFalse(text_evidence_sha256_equal(text.sha256, text.sha256))
        self.assertFalse(artifact_byte_sha256_equal(artifact.sha256, artifact.sha256))
        self.assertFalse(text_evidence_sha256_equal(artifact.to_json(), text.to_json()))
        self.assertFalse(artifact_byte_sha256_equal(text.to_json(), artifact.to_json()))

    def test_untyped_unknown_and_malformed_digest_documents_fail_closed(self) -> None:
        for raw, code in (
            ("0" * 64, "DIGEST_TYPE"),
            ({"domain": "future-domain", "sha256": "0" * 64}, "DIGEST_DOMAIN"),
            ({"domain": TEXT_EVIDENCE_DOMAIN, "sha256": "ABC"}, "DIGEST_INVALID"),
            ({"domain": TEXT_EVIDENCE_DOMAIN, "sha256": "0" * 64, "extra": True}, "DIGEST_FIELDS"),
        ):
            with self.subTest(code=code), self.assertRaises(DigestError) as caught:
                parse_text_digest(raw)
            self.assertEqual(code, caught.exception.code)

    def test_atomic_report_preserves_target_on_injected_failure(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-p1-014-atomic-") as directory:
            path = Path(directory) / "report.json"
            path.write_bytes(b"old\r\n")
            with self.assertRaises(RuntimeError):
                atomic_json(path, {"status": "PASS"}, lambda: (_ for _ in ()).throw(RuntimeError("injected")))
            self.assertEqual(b"old\r\n", path.read_bytes())
            self.assertEqual([], list(path.parent.glob(f".{path.name}.*.tmp")))

    def test_crlf_report_is_bounded_and_uses_actual_platform(self) -> None:
        report = crlf_report()
        self.assertEqual("PASS", report["status"])
        self.assertFalse(report["gitattributes_dependency"])
        self.assertEqual("REJECTED", report["invalid_utf8"])
        self.assertTrue(report["platform"]["system"])

    def test_crlf_report_rejects_wrong_native_platform(self) -> None:
        wrong = "windows-x86_64" if platform.system() != "Windows" else "linux-x86_64-glibc"
        report = crlf_report(wrong)
        self.assertEqual("FAIL", report["status"])
        self.assertEqual("PLATFORM_MISMATCH", report["issues"][0]["code"])

    def test_crlf_report_rejects_wrong_architecture_and_libc(self) -> None:
        with mock.patch.object(platform, "system", return_value="Linux"), \
                mock.patch.object(platform, "machine", return_value="aarch64"), \
                mock.patch.object(platform, "libc_ver", return_value=("musl", "1.2")):
            report = crlf_report("linux-x86_64-glibc")
        self.assertEqual("FAIL", report["status"])
        self.assertEqual("linux-arm64-musl", report["platform"]["identity"])
        self.assertIn("PLATFORM_MISMATCH", {item["code"] for item in report["issues"]})

    def test_crlf_report_reads_tracked_checkout_fixture_without_text_override(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-p1-014-checkout-") as directory:
            root = Path(directory)
            fixture = root / "docs/evidence/P1-014/fixtures/line-endings.txt"
            fixture.parent.mkdir(parents=True)
            fixture.write_bytes(b"alpha\r\nbeta\r\n")
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            (root / ".gitattributes").write_text("*.txt text\n", encoding="utf-8")
            report = crlf_report(root=root)
            self.assertEqual("PASS", report["status"])
            self.assertEqual("CRLF", report["checkout_fixture"]["line_endings"])
            self.assertFalse(report["gitattributes_dependency"])
            (root / ".gitattributes").write_text(
                "docs/evidence/P1-014/fixtures/line-endings.txt -text\n", encoding="utf-8"
            )
            blocked = crlf_report(root=root)
            self.assertEqual("FAIL", blocked["status"])
            self.assertIn("GITATTRIBUTES_DEPENDENCY", {item["code"] for item in blocked["issues"]})
            (root / ".gitattributes").write_text("*.txt -text\n", encoding="utf-8")
            broad = crlf_report(root=root)
            self.assertEqual("FAIL", broad["status"])
            self.assertEqual("unset", broad["effective_text_attribute"])
            (root / ".gitattributes").write_text("*.txt text eol=lf\n", encoding="utf-8")
            forced_lf = crlf_report(root=root)
            self.assertEqual("FAIL", forced_lf["status"])
            self.assertEqual("lf", forced_lf["effective_eol_attribute"])
            self.assertIn("GITATTRIBUTES_EOL_LF", {
                item["code"] for item in forced_lf["issues"]
            })

    def test_windows_crlf_report_requires_actual_crlf_checkout(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-p1-014-windows-checkout-") as directory:
            root = Path(directory)
            fixture = root / "docs/evidence/P1-014/fixtures/line-endings.txt"
            fixture.parent.mkdir(parents=True)
            fixture.write_bytes(b"alpha\nbeta\n")
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            with mock.patch("tools.evidence_digest.native_platform_identity",
                            return_value="windows-x86_64"):
                report = crlf_report("windows-x86_64", root=root)
            self.assertEqual("FAIL", report["status"])
            self.assertIn("WINDOWS_CHECKOUT_NOT_CRLF", {
                item["code"] for item in report["issues"]
            })

    def test_windows_workflow_is_pinned_and_runs_only_bounded_python_checks(self) -> None:
        workflow = (self.ROOT / ".github/workflows/p1-014-evidence-digest-boundary.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("runs-on: windows-latest", workflow)
        self.assertIn("actions/checkout@11d5960a326750d5838078e36cf38b85af677262", workflow)
        self.assertIn("actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02", workflow)
        self.assertIn("--expected-platform windows-x86_64", workflow)
        self.assertIn('- ".gitattributes"', workflow)
        self.assertIn('- ".github/actions/**"', workflow)
        self.assertNotIn("cjpm", workflow.lower())
        self.assertNotIn("soak", workflow.lower())

    def test_production_digest_imports_bootstrap_direct_cli_execution(self) -> None:
        marker = "from tools import " + "evidence_digest"
        checked: list[str] = []
        violations: list[str] = []
        for path in sorted((self.ROOT / "tools").rglob("*.py")):
            relative = path.relative_to(self.ROOT)
            if "tests" in relative.parts:
                continue
            source = path.read_text(encoding="utf-8")
            if marker not in source:
                continue
            checked.append(relative.as_posix())
            prefix = source.split(marker, 1)[0]
            parent_index = len(relative.parents) - 1
            expected_root = f"Path(__file__).resolve().parents[{parent_index}]"
            if "if __package__ in {None, \"\"}:" not in prefix or expected_root not in prefix:
                violations.append(relative.as_posix())
        self.assertGreater(len(checked), 40)
        self.assertEqual([], violations)

    def test_inventory_rejects_untyped_digest_anywhere_in_repository_tools(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-p1-014-inventory-") as directory:
            root = Path(directory)
            path = root / "tools/gates/new_tool.py"
            path.parent.mkdir(parents=True)
            path.write_text("import hashlib\nvalue = hashlib.sha256(b'x').hexdigest()\n", encoding="utf-8")
            report = digest_inventory(root)
            self.assertEqual("FAIL", report["status"])
            self.assertEqual("UNTYPED_DIGEST", report["issues"][0]["code"])

    def test_inventory_rejects_direct_sha256_import_and_untyped_shell_command(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-p1-014-inventory-") as directory:
            root = Path(directory)
            python_path = root / "tools/gates/new_tool.py"
            python_path.parent.mkdir(parents=True)
            python_path.write_text(
                "from hashlib import sha256\nvalue = sha256(b'x').hexdigest()\n",
                encoding="utf-8",
            )
            script = root / "scripts/check-report"
            script.parent.mkdir(parents=True)
            script.write_text("sha256sum report.json\n", encoding="utf-8")
            report = digest_inventory(root)
            self.assertEqual("FAIL", report["status"])
            self.assertEqual(2, len(report["issues"]))
            script.write_text(
                "# wirestack-digest-domain: artifact-bytes-v1\nsha256sum report.json\n",
                encoding="utf-8",
            )
            report = digest_inventory(root)
            self.assertEqual("FAIL", report["status"])
            self.assertEqual(2, len(report["issues"]))
            self.assertIn("invalid-artifact-on-text", report["domain_counts"])
            script.write_text(
                "# wirestack-digest-domain: artifact-bytes-v1\nsha256sum payload.tar.gz\n",
                encoding="utf-8",
            )
            report = digest_inventory(root)
            self.assertEqual("FAIL", report["status"])
            self.assertEqual(1, len(report["issues"]))
            self.assertIn("artifact-bytes", report["domain_counts"])

    def test_inventory_scans_non_python_tools_and_untyped_comparisons(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-p1-014-inventory-") as directory:
            root = Path(directory)
            shell = root / "tools/new_gate.sh"
            shell.parent.mkdir(parents=True)
            shell.write_text("sha256sum report.json\n", encoding="utf-8")
            python = root / "tools/gates/compare.py"
            python.parent.mkdir(parents=True)
            python.write_text(
                "def matches(report, expected):\n"
                "    return report.get('sha256') == expected\n",
                encoding="utf-8",
            )
            report = digest_inventory(root)
            self.assertEqual("FAIL", report["status"])
            self.assertEqual(2, len(report["issues"]))
            self.assertTrue(any(
                issue["detail"].endswith("bare-sha256-comparison")
                for issue in report["issues"]
            ))

    def test_inventory_scans_composite_actions(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-p1-014-inventory-") as directory:
            root = Path(directory)
            action = root / ".github/actions/evidence/action.yaml"
            action.parent.mkdir(parents=True)
            action.write_text(
                "runs:\n  using: composite\n  steps:\n    - shell: bash\n      run: sha256sum report.json\n",
                encoding="utf-8",
            )
            report = digest_inventory(root)
            self.assertEqual("FAIL", report["status"])
            self.assertEqual("UNTYPED_DIGEST", report["issues"][0]["code"])

    def test_inventory_rejects_alternate_hashlib_constructor_import(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-p1-014-inventory-") as directory:
            root = Path(directory)
            path = root / "tools/gates/new_tool.py"
            path.parent.mkdir(parents=True)
            path.write_text(
                "from hashlib import new\nvalue = new('sha256', b'x').hexdigest()\n",
                encoding="utf-8",
            )
            report = digest_inventory(root)
            self.assertEqual("FAIL", report["status"])
            self.assertEqual("UNTYPED_DIGEST", report["issues"][0]["code"])

    def test_inventory_rejects_typed_alias_and_raw_python_subprocess(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-p1-014-inventory-") as directory:
            root = Path(directory)
            path = root / "tools/gates/new_tool.py"
            path.parent.mkdir(parents=True)
            path.write_text(
                "import subprocess\n"
                "from tools.evidence_digest import artifact_byte_sha256 as digest\n"
                "value = digest(report_path)\n"
                "subprocess.run(['sha256sum', 'report.json'])\n",
                encoding="utf-8",
            )
            report = digest_inventory(root)
            self.assertEqual("FAIL", report["status"])
            self.assertIn("invalid-artifact-on-text", report["domain_counts"])
            self.assertIn("legacy-task-local", report["domain_counts"])

    def test_inventory_resolves_assigned_typed_callable_alias(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-p1-014-inventory-") as directory:
            root = Path(directory)
            path = root / "tools/gates/new_tool.py"
            path.parent.mkdir(parents=True)
            path.write_text(
                "from pathlib import Path\n"
                "from tools import evidence_digest\n"
                "digest = evidence_digest.artifact_byte_sha256\n"
                "value = digest(Path('report.json'))\n",
                encoding="utf-8",
            )
            report = digest_inventory(root)
            self.assertEqual("FAIL", report["status"])
            self.assertIn("invalid-artifact-on-text", report["domain_counts"])

    def test_inventory_resolves_assigned_text_path_before_byte_digest(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-p1-014-inventory-") as directory:
            root = Path(directory)
            path = root / "tools/gates/new_tool.py"
            path.parent.mkdir(parents=True)
            path.write_text(
                "from pathlib import Path\n"
                "from tools.evidence_digest import artifact_byte_sha256\n"
                "path = Path('report.json')\n"
                "value = artifact_byte_sha256(path)\n",
                encoding="utf-8",
            )
            report = digest_inventory(root)
            self.assertEqual("FAIL", report["status"])
            self.assertIn("invalid-artifact-on-text", report["domain_counts"])

    def test_inventory_resolves_keyword_text_path_before_byte_digest(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-p1-014-inventory-") as directory:
            root = Path(directory)
            path = root / "tools/gates/new_tool.py"
            path.parent.mkdir(parents=True)
            path.write_text(
                "from pathlib import Path\n"
                "from tools.evidence_digest import artifact_byte_sha256\n"
                "value = artifact_byte_sha256(path=Path('report.json'))\n",
                encoding="utf-8",
            )
            report = digest_inventory(root)
            self.assertEqual("FAIL", report["status"])
            self.assertIn("invalid-artifact-on-text", report["domain_counts"])

    def test_inventory_rejects_assigned_subprocess_and_os_system_commands(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-p1-014-inventory-") as directory:
            root = Path(directory)
            path = root / "scripts/new_gate.py"
            path.parent.mkdir(parents=True)
            path.write_text(
                "import os\nimport subprocess\n"
                "command = ['sha256sum', 'report.json']\n"
                "subprocess.run(command)\n"
                "os.system('sha256sum report.json')\n",
                encoding="utf-8",
            )
            report = digest_inventory(root)
            self.assertEqual("FAIL", report["status"])
            self.assertEqual(
                2,
                sum(issue["detail"].endswith("raw-digest-command")
                    for issue in report["issues"]),
            )

    def test_inventory_rejects_local_digest_wrapper(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-p1-014-inventory-") as directory:
            root = Path(directory)
            path = root / "tools/gates/new_tool.py"
            path.parent.mkdir(parents=True)
            path.write_text(
                "from pathlib import Path\n"
                "from tools.evidence_digest import artifact_byte_sha256\n"
                "def digest(path):\n    return artifact_byte_sha256(path)\n"
                "value = digest(Path('report.json'))\n",
                encoding="utf-8",
            )
            report = digest_inventory(root)
            self.assertEqual("FAIL", report["status"])
            self.assertTrue(any(
                issue["detail"].endswith(":digest") for issue in report["issues"]
            ))

    def test_inventory_rejects_openssl_and_embedded_python_digest_commands(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-p1-014-inventory-") as directory:
            root = Path(directory)
            path = root / "scripts/check-report"
            path.parent.mkdir(parents=True)
            path.write_text(
                "openssl dgst -sha256 docs/evidence/report.json\n"
                "python3 -c 'import hashlib; print(hashlib.sha256(open(\"report.json\", \"rb\").read()))'\n",
                encoding="utf-8",
            )
            report = digest_inventory(root)
            self.assertEqual("FAIL", report["status"])
            self.assertEqual(2, len(report["issues"]))

    def test_inventory_rejects_text_marker_on_raw_digest_command(self) -> None:
        with tempfile.TemporaryDirectory(prefix="wirestack-p1-014-inventory-") as directory:
            root = Path(directory)
            path = root / "scripts/check-report"
            path.parent.mkdir(parents=True)
            path.write_text(
                "# wirestack-digest-domain: text-utf8-lf-v1\nsha256sum report.json\n",
                encoding="utf-8",
            )
            report = digest_inventory(root)
            self.assertEqual("FAIL", report["status"])
            self.assertEqual(1, len(report["issues"]))
            self.assertIn("invalid-text-command", report["domain_counts"])

    def test_current_inventory_has_no_legacy_task_local_digest_calls(self) -> None:
        report = digest_inventory(self.ROOT)
        self.assertEqual("PASS", report["status"])
        self.assertNotIn("legacy-task-local", report["domain_counts"])
        self.assertGreater(report["domain_counts"].get("text-evidence", 0), 0)
        self.assertGreater(report["domain_counts"].get("artifact-bytes", 0), 0)


if __name__ == "__main__":
    unittest.main()
