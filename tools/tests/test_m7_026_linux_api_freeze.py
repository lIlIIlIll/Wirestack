from __future__ import annotations

import copy
import tempfile
import unittest
from pathlib import Path

from tools import m7_026_linux_api_freeze as api


class M7026LinuxApiFreezeTest(unittest.TestCase):
    def test_committed_baseline_and_report_are_current(self) -> None:
        report = api.validate()
        self.assertEqual("PASS", report["decision"])
        self.assertEqual("PASS_EXACT_BASELINE_MATCH", report["compatibilityEvidence"]["sourceAndInventory"])

    def test_body_only_change_is_stable_but_signature_change_is_not(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self.fixture(Path(temporary))
            baseline = api.build_inventory(root)
            source = root / "src/http/cancellation.cj"
            original = source.read_text(encoding="utf-8")
            source.write_text(original.replace("state.cancel()", "if (true) { state.cancel() } else { false }"), encoding="utf-8")
            self.assertEqual(baseline, api.build_inventory(root))
            source.write_text(original.replace("cancel(): Bool", "cancel(force!: Bool = false): Bool"), encoding="utf-8")
            with self.assertRaisesRegex(api.ApiFreezeError, "cancellation handle"):
                api.build_inventory(root)

    def test_package_identity_and_forbidden_types_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self.fixture(Path(temporary))
            manifest = root / "cjpm.toml"
            manifest.write_text(manifest.read_text(encoding="utf-8").replace('version = "0.1.0"', 'version = "1.0.0"'), encoding="utf-8")
            with self.assertRaisesRegex(api.ApiFreezeError, "public major changed"):
                api.build_inventory(root)
            manifest.write_text('[package]\nname = "wirestack"\nversion = "0.1.0"\n', encoding="utf-8")
            source = root / "src/http/legacy.cj"
            source.write_text("package wirestack.http\npublic class TrustAll {}\n", encoding="utf-8")
            with self.assertRaisesRegex(api.ApiFreezeError, "trust-all"):
                api.build_inventory(root)

    def test_openssl_metadata_bool_is_allowed_but_cipher_string_is_not(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self.fixture(Path(temporary))
            source = root / "src/tls/metadata.cj"
            source.write_text(
                "package wirestack.tls\n"
                "public let externalOpenSslDependency: Bool = false\n",
                encoding="utf-8",
            )
            api.build_inventory(root)
            source.write_text(
                "package wirestack.tls\n"
                "public func setOpenSslCipher(value: String): Unit {}\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(api.ApiFreezeError, "openssl-string"):
                api.build_inventory(root)

    def test_alias_target_member_change_changes_inventory(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = self.fixture(Path(temporary))
            baseline = api.build_inventory(root)
            target = root / "src/internal/model/package.cj"
            target.write_text(
                target.read_text(encoding="utf-8").replace("value(): Int64", "value(): String"),
                encoding="utf-8",
            )
            current = api.build_inventory(root)
            self.assertNotEqual(baseline["resolvedAliases"], current["resolvedAliases"])
            with self.assertRaisesRegex(api.ApiFreezeError, "resolved alias declarations changed"):
                api.compare_inventory(baseline, current)

    def test_inventory_comparison_reports_add_remove_and_change(self) -> None:
        baseline = {
            "schemaVersion": api.SCHEMA_VERSION,
            "package": {"name": "wirestack", "version": "0.1.0", "major": 0},
            "declarations": [
                {"package": "wirestack.http", "kind": "class", "name": "A", "signature": "public class A", "members": []},
                {"package": "wirestack.http", "kind": "class", "name": "B", "signature": "public class B", "members": []},
            ],
            "resolvedAliases": [],
        }
        current = copy.deepcopy(baseline)
        current["declarations"] = [
            {"package": "wirestack.http", "kind": "class", "name": "B", "signature": "public open class B", "members": []},
            {"package": "wirestack.http", "kind": "class", "name": "C", "signature": "public class C", "members": []},
        ]
        with self.assertRaisesRegex(api.ApiFreezeError, "removed=.*added=.*changed="):
            api.compare_inventory(baseline, current)

    def fixture(self, root: Path) -> Path:
        (root / "src/http").mkdir(parents=True)
        (root / "src/tls").mkdir(parents=True)
        (root / "src/internal/model").mkdir(parents=True)
        (root / "cjpm.toml").write_text(
            '[package]\nname = "wirestack"\nversion = "0.1.0"\n', encoding="utf-8"
        )
        (root / "src/package.cj").write_text("package wirestack\n", encoding="utf-8")
        (root / "src/tls/package.cj").write_text("package wirestack.tls\n", encoding="utf-8")
        (root / "src/internal/model/package.cj").write_text(
            "package wirestack.internal.model\n"
            "public interface Model {\n"
            "    func value(): Int64\n"
            "}\n",
            encoding="utf-8",
        )
        handles = []
        for name, scope in (
            ("HttpRequestCancellationHandle", "Request"),
            ("HttpConnectionCancellationHandle", "Connection"),
            ("HttpStreamCancellationHandle", "Stream"),
        ):
            handles.append(
                f"public class {name} <:\n"
                "    Resource {\n"
                f"    public prop scope: HttpCancellationScope {{ get() {{ HttpCancellationScope.{scope} }} }}\n"
                "    public prop isCancellationRequested: Bool { get() { false } }\n"
                "    public func cancel(): Bool { state.cancel() }\n"
                "}\n"
            )
        (root / "src/http/cancellation.cj").write_text(
            "package wirestack.http\n"
            "import wirestack.internal.model as model\n"
            "public enum HttpCancellationScope {\n"
            "    | Request\n"
            "    | Connection\n"
            "    | Stream\n"
            "}\n"
            + "".join(handles)
            + "public type PublicModel = model.Model\n",
            encoding="utf-8",
        )
        return root


if __name__ == "__main__":
    unittest.main()
