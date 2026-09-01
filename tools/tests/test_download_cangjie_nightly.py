from __future__ import annotations

import unittest

from tools import download_cangjie_nightly as nightly


def release() -> dict[str, object]:
    version = "1.3.0-alpha.20260831010012"
    return {
        "name": f"Nightly Build {version}",
        "tag_name": version,
        "assets": [
            {"name": f"cangjie-sdk-linux-x64-{version}.tar.gz"},
            {
                "name": f"cangjie-sdk-mac-aarch64-ios-{version}.tar.gz",
                "browser_download_url": "https://example.invalid/cangjie.tar.gz",
            },
        ],
    }


class DownloadCangjieNightlyTests(unittest.TestCase):
    def test_resolves_one_exact_official_asset_name(self) -> None:
        version, name, url = nightly.resolve_asset(release(), "mac-aarch64-ios")
        self.assertEqual("1.3.0-alpha.20260831010012", version)
        self.assertEqual(
            "cangjie-sdk-mac-aarch64-ios-1.3.0-alpha.20260831010012.tar.gz",
            name,
        )
        self.assertEqual("https://example.invalid/cangjie.tar.gz", url)

    def test_rejects_missing_duplicate_and_non_https_assets(self) -> None:
        missing = release()
        missing["assets"] = missing["assets"][:1]
        with self.assertRaises(nightly.DownloadError):
            nightly.resolve_asset(missing, "mac-aarch64-ios")

        duplicate = release()
        duplicate["assets"] = list(duplicate["assets"]) + [duplicate["assets"][1]]
        with self.assertRaises(nightly.DownloadError):
            nightly.resolve_asset(duplicate, "mac-aarch64-ios")

        insecure = release()
        insecure["assets"][1]["browser_download_url"] = "http://example.invalid/sdk"
        with self.assertRaises(nightly.DownloadError):
            nightly.resolve_asset(insecure, "mac-aarch64-ios")


if __name__ == "__main__":
    unittest.main()
