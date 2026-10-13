"""Consumer-visible fail-closed controls for installed application acceptance."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from tools import m11_004_installed_consumers as apps
from tools.evidence_digest import artifact_byte_digest


class InstalledApplicationBoundaryTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def application(self, name="cli", import_line="wirestack.http.*"):
        app = self.root / name
        (app / "src").mkdir(parents=True)
        (app / "cjpm.toml").write_text(f'''[package]
name = "wirestack_m11_004_{name}"
output-type = "executable"
[dependencies]
wirestack = {{path = "../../install/wirestack"}}
''')
        (app / "src/main.cj").write_text(f"package wirestack_m11_004_{name}\nimport {import_line}\n")
        return app

    def test_consumer_cannot_escape_into_checkout_or_an_extra_dependency(self):
        for entry in ('wirestack = {path="../../checkout"}', 'wirestack = {path="../../install/wirestack"}\nprivate = {path="../../checkout"}'):
            with self.subTest(entry=entry):
                app = self.application()
                manifest = app / "cjpm.toml"
                manifest.write_text(manifest.read_text().replace('wirestack = {path = "../../install/wirestack"}', entry))
                with self.assertRaisesRegex(ValueError, "relative extracted package"):
                    apps.validate_app(app, "cli")
                import shutil
                shutil.rmtree(app)

    def test_internal_net_or_legacy_import_is_rejected(self):
        for name in ("wirestack.internal.http1.*", "std.net.*", "stdx.net.http.*"):
            with self.subTest(name=name):
                app = self.application(import_line=name)
                with self.assertRaisesRegex(ValueError, "internal or legacy"):
                    apps.validate_app(app, "cli")
                import shutil
                shutil.rmtree(app)

    def test_optional_module_cannot_leak_into_raw_cli(self):
        app = self.application(import_line="wirestack.gzip.*")
        with self.assertRaisesRegex(ValueError, "optional feature"):
            apps.validate_app(app, "cli")

    def test_consumer_cannot_replace_native_linkage(self):
        app = self.application()
        with (app / "cjpm.toml").open("a") as target:
            target.write('[target.x86_64-unknown-linux-gnu]\nlink-option="-lssl"\n')
        with self.assertRaisesRegex(ValueError, "override"):
            apps.validate_app(app, "cli")

    def test_documentation_byte_drift_missing_app_and_duplicate_are_rejected(self):
        entries = []
        for name in apps.APP_NAMES:
            app = self.application(name=name)
            (app / "src/main.cj").write_text(f"// DOC-BEGIN {name}\nprintln(1)\n// DOC-END {name}\n")
            entries.append(f"<!-- compiled: {name}/src/main.cj#{name} -->\n```cangjie\nprintln(1)\n```\n")
        guide = self.root / "guide.md"
        guide.write_text("\n".join(entries))
        self.assertEqual(set(apps.validate_docs(guide, self.root)), {f"{name}/src/main.cj#{name}" for name in apps.APP_NAMES})
        for text in ("\n".join(entries).replace("println(1)", "println(2)", 1), "\n".join(entries[:-1]), "\n".join([*entries, entries[0]])):
            with self.subTest(text=text):
                guide.write_text(text)
                with self.assertRaises(ValueError):
                    apps.validate_docs(guide, self.root)

    def test_missing_static_archive_and_mutated_bytes_fail_inventory(self):
        installed = self.root / "installed"
        records = []
        for name in apps.NATIVE_ARCHIVES:
            path = installed / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"!<arch>\ncontrolled archive payload")
            records.append({"path": name, "bytes": path.stat().st_size, "sha256": artifact_byte_digest(path).sha256})
        manifest = {"payload": records}
        apps.validate_installed(installed, manifest)
        first = installed / apps.NATIVE_ARCHIVES[0]
        first.write_bytes(b"!<arch>\ncontrolled archive payloae")
        with self.assertRaises(ValueError):
            apps.validate_installed(installed, manifest)
        first.unlink()
        with self.assertRaises(ValueError):
            apps.validate_installed(installed, manifest)

    def test_implicit_system_dependency_is_not_accepted(self):
        apps.validate_needed(["libcangjie-runtime.so", "libc.so.6"])
        for names in ([], ["libssl.so.3"], ["libz.so.1"], ["libvendor-example.so"]):
            with self.subTest(names=names):
                with self.assertRaises(ValueError):
                    apps.validate_needed(names)

    def test_missing_or_duplicate_native_scenario_cannot_complete(self):
        lines = [f"CHECK {name} PASS" for name in sorted(apps.REQUIRED_CHECKS["cli"])]
        complete = "\n".join([*lines, "APP_ACCEPTANCE_PASS"])
        self.assertEqual(set(apps.validate_checks(complete, "cli")), apps.REQUIRED_CHECKS["cli"])
        for text in ("\n".join([*lines[1:], "APP_ACCEPTANCE_PASS"]), complete + "\n" + lines[0], complete.replace("APP_ACCEPTANCE_PASS", ""), complete + "\nCHECK cli_unknown PASS"):
            with self.subTest(text=text):
                with self.assertRaises(ValueError):
                    apps.validate_checks(text, "cli")


    def test_m9_marker_is_exactly_bound_to_consumer_mode_and_unique(self):
        all_markers = set(apps.M9_PASS_MARKERS.values())
        for (consumer, mode), expected in apps.M9_PASS_MARKERS.items():
            with self.subTest(consumer=consumer, mode=mode):
                self.assertIsNone(apps.validate_m9_pass_marker(expected + "\n", consumer, mode))
                wrong = next(marker for marker in all_markers if marker != expected)
                for output in ("", wrong + "\n", expected + "\n" + expected + "\n",
                               wrong + "\n" + expected + "\n"):
                    with self.subTest(output=output), self.assertRaisesRegex(ValueError, "expected exactly"):
                        apps.validate_m9_pass_marker(output, consumer, mode)

    def test_wrong_m9_mode_marker_cannot_mark_integration_pass(self):
        root = self.root
        for path in (root / "examples/linux/m9_002/socket_options.cj",
                     root / "examples/linux/m9_003/udp_lifecycle.cj"):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("// controlled installed-consumer fixture\n")
        work = root / "work"
        work.mkdir()
        report = {"toolchain": {"compiler": "Compiler: 1.1.3 qualified"}}

        def run(name, argv, cwd, **kwargs):
            if name.endswith("-build"):
                return ""
            return "M9_002_HTTP_CONNECTOR_PASS\n"

        with patch.object(apps, "ROOT", root), \
             patch.object(apps.release, "consumer_manifest", return_value="wirestack_release_smoke"), \
             patch.object(apps.socket, "if_nametoindex", return_value=1):
            with self.assertRaisesRegex(ValueError, "M9 options/options marker mismatch"):
                apps.run_m9(root / "install", work, {}, run, report)
        self.assertNotIn("m9_integration", report)
    def test_unused_proxy_is_stopped_without_retained_worker(self):
        with apps.SingleConnectProxy() as proxy:
            thread = proxy.thread
        self.assertFalse(thread.is_alive())


if __name__ == "__main__":
    unittest.main()
