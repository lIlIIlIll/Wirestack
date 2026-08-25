# Repository layout and build boundaries

This document covers repository-only structure. Public package and runtime
architecture is described in [the architecture guide](../architecture.md).

## Source groups

| Path | Role | Published in core |
|---|---|---|
| `src/lib_*.cj` | Pure Cangjie runtime and public API | yes |
| `src/example_support.cj` | repository fixtures and benchmark models | no |
| `src/test_*.cj` | white-box and public-contract tests | no |
| `packages/yjson_macros/` | declaration and expression macros | separate package |
| `packages/yjson_all/` | aggregate import | separate package |
| `packages/yjson_native/` | Custom Native facade and tests | optional package |
| `packages/yjson_schema_formats/` | Internationalized Schema format provider | optional package |
| `packages/yjson_yyjson/` | yyjson facade, vendored source, and tests | optional package |
| `packages/*_integration/` | external-style consumers | no |
| `native/` | scanner, Custom Compact, yyjson adapter, and C tests | native packages only |
| `release/package-manifests/` | publication manifests | staging input |

## Development and release manifests

The root development manifest depends on `yjson_macros` because repository
fixtures use `@JsonCodec`. `scripts/release_package_stage.py` constructs the
actual publication layout: core receives only `src/lib_*.cj` and the release
`yjson.toml`, whose dependency table is empty.

Native package staging additionally copies its `build.cj`, C sources, headers,
and build helper. `yjson_yyjson` also receives the vendored yyjson source and
license. `scripts/release_registry_rehearsal.py` rejects path dependencies and
build artifacts before exercising isolated consumers.

## Generated code

There is no repository-wide codec-generation build step and no checked-in
`generated_json_codecs.cj`. `@JsonCodec` expands in each declaration's package.
The apparent generated fixtures in root builds are macro expansions of
`src/example_support.cj` and test declarations.

## Build hooks

Only optional packages with native dependencies own yjson build hooks:

- `packages/yjson_native/build.cj` builds scanner and Custom Compact archives.
- `packages/yjson_schema_formats/build.cj` builds the narrow libidn2 validation seam.
- `packages/yjson_yyjson/build.cj` builds scanner, Custom Compact support, and
  the vendored yyjson adapter.
- `packages/benchmarks/build.cj` is benchmark infrastructure, not a published
  application dependency.

## Structural debt

- Repository fixtures live beside production source because package-local tests
  exercise internal readers and scanners. Release staging must continue to
  exclude them.
- Development and publication dependency graphs intentionally differ. Both
  manifests need release-gate coverage to prevent a false runtime dependency on
  the macro package.
- Native tuning selectors and low-level backend seams are public for
  qualification or generated-code needs; new application documentation should
  not promote them as default entry points.
