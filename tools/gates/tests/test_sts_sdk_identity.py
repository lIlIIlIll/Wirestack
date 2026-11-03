from __future__ import annotations

import io
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest import mock

from tools import evidence_digest
from tools.gates import sts_sdk_identity as identity


class StsSdkIdentityTests(unittest.TestCase):
    def make_fixture(
        self, directory: Path, *, archive_kind: str = "tar.gz", system: str = "Darwin"
    ) -> tuple[Path, Path, dict[str, object]]:
        sdk_root = directory / "sdk"
        sdk_root.mkdir()
        files = {
            "bin/cjc": b"compiler tool bytes",
            "tools/bin/cjpm": b"project manager tool bytes",
            "runtime/lib/libcangjie-runtime.dylib": b"runtime bytes",
        }
        for relative, content in files.items():
            installed = sdk_root / relative
            installed.parent.mkdir(parents=True, exist_ok=True)
            installed.write_bytes(content)
            installed.chmod(0o755 if relative.endswith(("/cjc", "/cjpm")) else 0o644)

        archive_name = (
            "cangjie-sdk-mac-aarch64-1.2.0.tar.gz"
            if archive_kind == "tar.gz"
            else "cangjie-sdk-windows-x86_64-1.2.0.zip"
        )
        archive = directory / archive_name
        if archive_kind == "tar.gz":
            with tarfile.open(archive, mode="w:gz") as package:
                root = tarfile.TarInfo("cangjie")
                root.type = tarfile.DIRTYPE
                package.addfile(root)
                for relative, content in files.items():
                    member = tarfile.TarInfo(f"cangjie/{relative}")
                    member.size = len(content)
                    member.mode = 0o755 if relative.endswith(("/cjc", "/cjpm")) else 0o644
                    package.addfile(member, io.BytesIO(content))
        else:
            with zipfile.ZipFile(archive, mode="w") as package:
                for relative, content in files.items():
                    member = zipfile.ZipInfo(f"cangjie/{relative}")
                    member.external_attr = (
                        (0o100755 if relative.endswith(("/cjc", "/cjpm")) else 0o100644)
                        << 16
                    )
                    package.writestr(member, content)

        version = "1.2.0"
        native_target = "aarch64-apple-darwin" if system == "Darwin" else "x86_64-w64-mingw32"
        pin: dict[str, object] = {
            "schema_version": 1,
            "channel": "STS",
            "version": version,
            "platform": {
                "system": system,
                "machines": ["arm64", "aarch64"] if system == "Darwin" else ["AMD64", "x86_64"],
                "native_target": native_target,
            },
            "archive": {
                "name": archive_name,
                "sha256": evidence_digest.artifact_byte_digest(archive).sha256,
                "size_bytes": archive.stat().st_size,
                "archive_prefix": "cangjie",
            },
        }
        return sdk_root, archive, pin

    def capture_with_mocked_host(
        self, sdk_root: Path, archive: Path, pin: dict[str, object]
    ) -> dict[str, object]:
        platform_pin = pin["platform"]
        assert isinstance(platform_pin, dict)
        system = platform_pin["system"]
        machine = "arm64" if system == "Darwin" else "AMD64"

        native_target = platform_pin["native_target"]

        def run(command: list[str], **kwargs: object) -> object:
            tool = Path(command[0]).name.lower()
            output = (
                f"Cangjie Compiler: 1.2.0\nTarget: {native_target}"
                if tool == "cjc"
                else "Cangjie Project Manager: 1.2.0"
            )
            return identity.subprocess.CompletedProcess(command, 0, stdout=output)

        with (
            mock.patch.object(identity.platform, "system", return_value=system),
            mock.patch.object(identity.platform, "machine", return_value=machine),
            mock.patch.object(identity.subprocess, "run", side_effect=run),
        ):
            return identity.capture_sdk_identity(sdk_root, archive, pin)

    def test_tar_sdk_receipt_binds_archive_tree_and_native_tools(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sdk_root, archive, pin = self.make_fixture(Path(temporary))
            self.assertEqual(archive.stat().st_size, pin["archive"]["size_bytes"])
            receipt = self.capture_with_mocked_host(sdk_root, archive, pin)

        self.assertEqual("STS", receipt["channel"])
        self.assertEqual("1.2.0", receipt["version"])
        self.assertEqual("artifact-bytes-v1", receipt["archive"]["domain"])
        self.assertEqual(3, receipt["matched_archive_files"])
        self.assertEqual("bin/cjc", receipt["cjc"]["relative_path"])
        self.assertEqual("tools/bin/cjpm", receipt["cjpm"]["relative_path"])
        self.assertEqual("aarch64-apple-darwin", receipt["platform"]["native_target"])

    def test_archive_size_pin_requires_positive_exact_integer_and_exact_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sdk_root, archive, pin = self.make_fixture(Path(temporary))
            actual_size = archive.stat().st_size
            candidates: list[tuple[str, object]] = [
                ("missing", None),
                ("boolean", True),
                ("zero", 0),
                ("fraction", float(actual_size)),
                ("wrong", actual_size + 1),
            ]
            for label, value in candidates:
                candidate_pin = dict(pin)
                candidate_archive = dict(pin["archive"])
                candidate_pin["archive"] = candidate_archive
                if label == "missing":
                    candidate_archive.pop("size_bytes")
                else:
                    candidate_archive["size_bytes"] = value
                message = (
                    "positive integer archive size"
                    if label in {"missing", "boolean", "zero", "fraction"}
                    else "does not match its pinned size"
                )
                with self.subTest(size=label), self.assertRaisesRegex(
                    identity.SDKIdentityError, message
                ):
                    identity.capture_sdk_identity(sdk_root, archive, candidate_pin)

    def test_installed_tree_drift_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sdk_root, archive, pin = self.make_fixture(Path(temporary))
            (sdk_root / "runtime/lib/libcangjie-runtime.dylib").write_bytes(b"changed")
            with (
                mock.patch.object(identity.platform, "system", return_value="Darwin"),
                mock.patch.object(identity.platform, "machine", return_value="arm64"),
                self.assertRaises(identity.SDKIdentityError),
            ):
                identity.capture_sdk_identity(sdk_root, archive, pin)

    def test_unarchived_installed_file_and_wrong_archive_digest_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sdk_root, archive, pin = self.make_fixture(Path(temporary))
            (sdk_root / "extra.file").write_bytes(b"not in archive")
            with (
                mock.patch.object(identity.platform, "system", return_value="Darwin"),
                mock.patch.object(identity.platform, "machine", return_value="arm64"),
                self.assertRaises(identity.SDKIdentityError),
            ):
                identity.capture_sdk_identity(sdk_root, archive, pin)

            (sdk_root / "extra.file").unlink()
            pin["archive"]["sha256"] = "0" * 64
            with self.assertRaisesRegex(identity.SDKIdentityError, "pinned SHA-256"):
                identity.capture_sdk_identity(sdk_root, archive, pin)

    def test_zip_sdk_identity_supports_windows_native_platform(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            sdk_root, archive, pin = self.make_fixture(
                Path(temporary), archive_kind="zip", system="Windows"
            )
            receipt = self.capture_with_mocked_host(sdk_root, archive, pin)

        self.assertEqual("Windows", receipt["platform"]["system"])
        self.assertEqual("x86_64-w64-mingw32", receipt["cjc"]["target"])
        self.assertEqual(3, receipt["matched_archive_files"])


if __name__ == "__main__":
    unittest.main()
