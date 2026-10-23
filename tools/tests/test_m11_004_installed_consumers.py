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

    def test_package_level_linker_and_compiler_overrides_are_rejected(self):
        for field, value in (("link-option", '"-lssl"'), ("override-compile-option", '"-I/vendor/include"'),
                             ("compile-option", '"-O0"'), ("package-configuration", '{vendor = "custom"}')):
            with self.subTest(field=field):
                app = self.application()
                manifest = app / "cjpm.toml"
                manifest.write_text(manifest.read_text().replace(
                    'output-type = "executable"', f'output-type = "executable"\n{field} = {value}'))
                with self.assertRaises(apps.ManifestContractError) as raised:
                    apps.validate_app(app, "cli")
                self.assertEqual(raised.exception.code, "MANIFEST_PACKAGE_OVERRIDE")
                import shutil
                shutil.rmtree(app)

    def test_unknown_package_field_is_rejected(self):
        app = self.application()
        manifest = app / "cjpm.toml"
        manifest.write_text(manifest.read_text().replace(
            'output-type = "executable"', 'output-type = "executable"\nunexpected-linker-setting = "x"'))
        with self.assertRaises(apps.ManifestContractError) as raised:
            apps.validate_app(app, "cli")
        self.assertEqual(raised.exception.code, "MANIFEST_PACKAGE_FIELD")

    def test_empty_package_option_fields_stay_permitted(self):
        app = self.application()
        manifest = app / "cjpm.toml"
        manifest.write_text(manifest.read_text().replace(
            'output-type = "executable"',
            'output-type = "executable"\ncompile-option = ""\noverride-compile-option = ""\n'
            'link-option = ""\npackage-configuration = {}\ntarget-dir = ""\nscript-dir = ""\ndescription = "consumer"'))
        self.assertEqual(apps.validate_app(app, "cli"), ["wirestack.http.*"])

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


    def test_every_tagged_region_of_a_multi_snippet_application_is_required(self):
        entries = []
        for name in apps.APP_NAMES:
            app = self.application(name=name)
            tags = [f"{name}-one", f"{name}-two"] if name == "streams" else [name]
            source = "".join(f"// DOC-BEGIN {tag}\nprintln({index})\n// DOC-END {tag}\n" for index, tag in enumerate(tags))
            (app / "src/main.cj").write_text(f"package wirestack_m11_004_{name}\n{source}")
            for index, tag in enumerate(tags):
                entries.append(f"<!-- compiled: {name}/src/main.cj#{tag} -->\n```cangjie\nprintln({index})\n```\n")
        guide = self.root / "guide.md"
        guide.write_text("\n".join(entries))
        documented = apps.validate_docs(guide, self.root)
        self.assertIn("streams/src/main.cj#streams-two", documented)
        guide.write_text("\n".join(entry for entry in entries if "#streams-two" not in entry))
        with self.assertRaisesRegex(ValueError, "streams/src/main.cj#streams-two"):
            apps.validate_docs(guide, self.root)

    def test_untracked_application_snippet_is_still_required(self):
        entries = []
        for name in apps.APP_NAMES:
            app = self.application(name=name)
            (app / "src/main.cj").write_text(f"package wirestack_m11_004_{name}\n// DOC-BEGIN {name}\nprintln(1)\n// DOC-END {name}\n")
            entries.append(f"<!-- compiled: {name}/src/main.cj#{name} -->\n```cangjie\nprintln(1)\n```\n")
        guide = self.root / "guide.md"
        guide.write_text("\n".join(entries))
        self.assertEqual(len(apps.validate_docs(guide, self.root)), len(apps.APP_NAMES))
        (self.root / "cli/src/extra.cj").write_text("package wirestack_m11_004_cli\n// DOC-BEGIN extra\nprintln(2)\n// DOC-END extra\n")
        with self.assertRaisesRegex(ValueError, "cli/src/extra.cj#extra"):
            apps.validate_docs(guide, self.root)

    def test_unclosed_caller_owned_tls_configuration_is_rejected(self):
        for name in apps.APP_NAMES:
            app = self.application(name=name)
            (app / "src/main.cj").write_text(f"package wirestack_m11_004_{name}\n")
        source = self.root / "streams/src/main.cj"
        unclosed = ["package wirestack_m11_004_streams", "func run(): Unit {",
            "    let config = HttpServerTlsConfig([], [])",
            "    let server = HttpServer.builder().tls(config).build()", "}", ""]
        source.write_text("\n".join(unclosed))
        with self.assertRaisesRegex(ValueError, "never closes its HttpServerTlsConfig owner config"):
            apps.validate_tls_ownership(self.root)
        inline = ["package wirestack_m11_004_streams", "func run(): Unit {",
            "    let server = HttpServer.builder().tls(HttpServerTlsConfig([], [])).build()", "}", ""]
        source.write_text("\n".join(inline))
        with self.assertRaisesRegex(ValueError, "passes an unowned HttpServerTlsConfig"):
            apps.validate_tls_ownership(self.root)
        closed = ["package wirestack_m11_004_streams", "func run(): Unit {",
            "    let config = HttpServerTlsConfig([], [])",
            "    let server = HttpServer.builder().tls(config).build()",
            "    try { server.close() } finally { config.close() }", "}", ""]
        source.write_text("\n".join(closed))
        self.assertEqual(apps.validate_tls_ownership(self.root), {"HttpServerTlsConfig": 1, "HttpClientTlsConfig": 0})

    def test_optional_binding_tls_configuration_is_recognized_as_owned(self):
        for name in apps.APP_NAMES:
            app = self.application(name=name)
            (app / "src/main.cj").write_text(f"package wirestack_m11_004_{name}\n")
        optional = ["package wirestack_m11_004_cli", "func run(trust: String): Unit {",
            "    let config = if (trust.isEmpty()) { None<HttpClientTlsConfig> } else { Some(HttpClientTlsConfig([])) }",
            "    let client = HttpClient.builder().build()",
            "    try { } finally { client.close(); if (let Some(value) <- config) { value.close() } }", "}", ""]
        (self.root / "cli/src/main.cj").write_text("\n".join(optional))
        self.assertEqual(apps.validate_tls_ownership(self.root), {"HttpServerTlsConfig": 0, "HttpClientTlsConfig": 1})

    def test_compiled_examples_close_every_tls_configuration(self):
        owners = apps.validate_tls_ownership(apps.APPS)
        self.assertGreater(owners["HttpServerTlsConfig"], 0)
        self.assertGreater(owners["HttpClientTlsConfig"], 0)

    def test_flooding_child_fails_with_a_typed_capture_error(self):
        stdout = self.root / "stdout.raw"
        stderr = self.root / "stderr.raw"
        code, timed_out = apps.run_captured(["python3", "-c", "print('bounded')"], self.root, {}, stdout, stderr, 30)
        self.assertEqual((code, timed_out), (0, False))
        self.assertEqual(stdout.read_text(), "bounded\n")
        flood = "import sys\nwhile True: sys.stdout.write('x' * 8192)"
        with self.assertRaises(apps.EvidenceCaptureError) as raised:
            apps.run_captured(["python3", "-c", flood], self.root, {}, stdout, stderr, 60)
        self.assertEqual(raised.exception.code, "CAPTURE_LIMIT")
        self.assertLessEqual(stdout.stat().st_size, apps.CAPTURE_LIMIT_BYTES)

    def test_captured_log_normalization_stops_at_the_cap(self):
        source = self.root / "flood.log"
        source.write_text("line\n" * (apps.CAPTURE_LIMIT_BYTES // 4))
        destination = self.root / "normalized.log"
        written, truncated = apps.normalize_capture(source, destination, lambda line: line)
        self.assertTrue(truncated)
        self.assertLessEqual(written, apps.CAPTURE_LIMIT_BYTES)
        self.assertEqual(destination.stat().st_size, written)

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
