# yjson architecture

## Scope

The repository contains the `yjson` library package, a build-time codec
generator, a scanner linked as a static archive, and consumer packages for
benchmarks and examples. White-box tests remain in the library package because
they use internal reader/scanner APIs.

## Public API layers

- `YJson` is the primary strongly typed API. It uses `JsonDirectCodec<T>` and
  selects `JsonFastReader` for default read configuration when the codec supports
  the fast path.
- `YJsonAst` is the AST-oriented compatibility API. It converts through
  `JsonValueCodec<T>` and materializes `JsonValue` nodes.
- `JsonValue` and its subclasses form the public JSON AST.
- `JsonReadConfig`, `JsonWriteConfig`, and `JsonCodecConfig` own behavior policy.

## Typed decode path

```text
YJson.decodeStringWith / decodeBytesWith / decodeFromStreamWith
├── default configuration and fast-capable codec
│   └── JsonFastReader
│       └── generated or built-in codec
│           ├── compact/ordered Cangjie path
│           ├── sequential fallback
│           └── conditional native scan path
└── general configuration
    └── JsonDirectReader
```

The native path is cost-gated. Arrays must meet both byte-size and element-count
thresholds before offset indexing is used; smaller arrays remain on sequential
decoding.

## Encode path

```text
YJson.encodeStringWith / encodeBytesWith / encodeToStreamWith
└── generated or built-in codec
    └── JsonDirectWriter
        ├── DirectStringWriterTarget
        ├── DirectBytesWriterTarget
        └── DirectStreamWriterTarget
```

## AST path

```text
YJson.parse / YJsonAst.parse
└── JsonValue.parse
    └── JsonParser
        └── json_parser_core

YJson.stringify / YJsonAst.stringify
└── json_stream_writer
    └── JsonDirectWriter for compact output
```

## Build-time generation

`cjpm` invokes `build.cj` during `pre-build`:

1. `scripts/build_native_scanner.py` compiles `native/yjson_scanner.c` into
   `target/native/libyjson_scanner.a`.
2. The generator walks Cangjie files under `src/` and collects declarations
   annotated with `@JsonCodec`.
3. It writes specialized codecs to `src/generated_json_codecs.cj` only when the
   rendered content changes.

All scanned files must declare the same Cangjie package. The generated file is a
build artifact with source-level visibility because the package exports generated
codec constants such as `PersonJson`.

## Repository boundaries

- `src/lib_*.cj`: production Cangjie implementation.
- `src/generated_*.cj`: generated codecs.
- `src/test_*.cj`: package-local tests.
- `packages/benchmarks/`: public benchmark consumer package.
- `packages/examples/`: executable example consumer package.
- `native/`: the scanner ABI and C implementation.
- `benchmarks/cjfast_json/`: adapter copied into a pinned cjfast_json checkout.
- `benchmarks/java_fastjson2/`: standalone Java comparison harness.
- `scripts/`: reproducible build and benchmark orchestration.
- `target/`, `.cache/`, and `build-script-cache/`: disposable generated state.

## Packaging boundary

The root package keeps production code, white-box tests, and fixture declarations
together. This is intentional: regression tests use internal scanner APIs, and
the generated codecs include public fixture types consumed by the other packages.

The root files use `lib_` and `test_` prefixes because the active cjpm version
scans only the package source directory itself.

## Known structural debt

- `build.cj` still combines native orchestration, AST discovery, model analysis,
  and rendering. Splitting it requires first confirming how the active cjpm version
  compiles multi-file build scripts.
- A future test-package split must first extract or replace the white-box scanner
  assertions.
- `json_example_support.cj` contains public fixture types because their generated
  codecs are currently consumed by tests and benchmarks.
