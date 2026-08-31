#!/usr/bin/env python3
"""Regression tests for public Cangjie declaration discovery."""

from __future__ import annotations

import importlib.util
import pathlib
import tempfile
import unittest
from unittest import mock


SCRIPT = pathlib.Path(__file__).with_name("generate_public_api_snapshot.py")
SPEC = importlib.util.spec_from_file_location("generate_public_api_snapshot", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
SNAPSHOT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SNAPSHOT)


class CangjieDeclarationTest(unittest.TestCase):
    def declarations(self, source: str) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            path = root / "fixture.cj"
            path.write_text(source, encoding="utf-8")
            with mock.patch.object(SNAPSHOT, "ROOT", root):
                return SNAPSHOT.cangjie_declarations("fixture", path)

    def test_excludes_public_members_of_non_public_types(self) -> None:
        declarations = self.declarations(
            """
private class PrivateAdapter <:
    ToString
{
    public init() {}
    public func close(): Unit {}
}

class InternalAdapter {
    public func read(): Int64 { 0 }
}

public func exportedFactory(): Int64 { 1 }
"""
        )

        self.assertEqual(
            declarations,
            ["fixture|fixture.cj|<top-level>|public func exportedFactory(): Int64"],
        )

    def test_keeps_members_of_public_types(self) -> None:
        declarations = self.declarations(
            """
public class PublicApi {
    public init() {}
    public func value(): Int64 { 1 }
}

public interface PublicContract <:
    ToString
{
    func read(): Int64
}

public enum PublicChoice {
    | First
    | Second(Int64)
}
"""
        )

        self.assertEqual(
            declarations,
            [
                "fixture|fixture.cj|<top-level>|public class PublicApi",
                "fixture|fixture.cj|PublicApi|public init()",
                "fixture|fixture.cj|PublicApi|public func value(): Int64",
                "fixture|fixture.cj|<top-level>|public interface PublicContract <: ToString",
                "fixture|fixture.cj|PublicContract|func read(): Int64",
                "fixture|fixture.cj|<top-level>|public enum PublicChoice",
                "fixture|fixture.cj|PublicChoice|| First",
                "fixture|fixture.cj|PublicChoice|| Second(Int64)",
            ],
        )

    def test_excludes_public_nested_type_inside_private_type(self) -> None:
        declarations = self.declarations(
            """
private class PrivateOuter {
    public class HiddenNested {
        public func hidden(): Unit {}
    }
}

public class PublicOuter {
    public class VisibleNested {
        public func visible(): Unit {}
    }
}
"""
        )

        self.assertEqual(
            declarations,
            [
                "fixture|fixture.cj|<top-level>|public class PublicOuter",
                "fixture|fixture.cj|PublicOuter|public class VisibleNested",
                "fixture|fixture.cj|VisibleNested|public func visible(): Unit",
            ],
        )

    def test_generate_discovers_public_api_in_nested_source_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            nested = root / "src" / "nested"
            nested.mkdir(parents=True)
            (nested / "public_api.cj").write_text(
                "package fixture\npublic func nestedApi(): Int64 { 1 }\n",
                encoding="utf-8",
            )
            with mock.patch.object(SNAPSHOT, "ROOT", root), \
                    mock.patch.object(SNAPSHOT, "PACKAGE_ROOTS", {"fixture": root / "src"}):
                generated = SNAPSHOT.generate()
            self.assertIn(
                "fixture|src/nested/public_api.cj|<top-level>|public func nestedApi(): Int64",
                generated,
            )

    def test_generate_excludes_cjpm_suffix_test_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "src"
            source.mkdir(parents=True)
            (source / "runtime.cj").write_text(
                "package fixture\npublic func runtimeApi(): Unit {}\n",
                encoding="utf-8",
            )
            (source / "runtime_test.cj").write_text(
                "package fixture\npublic func testFixture(): Unit {}\n",
                encoding="utf-8",
            )
            with mock.patch.object(SNAPSHOT, "ROOT", root), \
                    mock.patch.object(SNAPSHOT, "PACKAGE_ROOTS", {"fixture": source}):
                generated = SNAPSHOT.generate()
            self.assertIn("runtimeApi", generated)
            self.assertNotIn("testFixture", generated)

    def test_c_prototypes_exclude_yj_testing_guards(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            header = root / "fixture.h"
            header.write_text(
                """
int32_t YJ_Public(void);
#if defined(YJ_TESTING)
void YJ_TestOnly(void);
#else
uint32_t YJ_ReleaseOnly(void);
#endif
#ifndef YJ_TESTING
uint64_t YJ_AlsoReleaseOnly(void);
#else
void YJ_AlsoTestOnly(void);
#endif
""",
                encoding="utf-8",
            )
            with mock.patch.object(SNAPSHOT, "ROOT", root):
                declarations = SNAPSHOT.c_prototypes(header)
            joined = "\n".join(declarations)
            self.assertIn("YJ_Public", joined)
            self.assertIn("YJ_ReleaseOnly", joined)
            self.assertIn("YJ_AlsoReleaseOnly", joined)
            self.assertNotIn("YJ_TestOnly", joined)
            self.assertNotIn("YJ_AlsoTestOnly", joined)


if __name__ == "__main__":
    unittest.main()
