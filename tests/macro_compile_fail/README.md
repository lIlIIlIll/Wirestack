# Compile-fail fixtures for the `@JsonCodec` macro

Each `.cj` file in this directory is a minimal Cangjie source that must FAIL to
compile: it exercises one rejection branch of `packages/yjson_macros/src/json_codec.cj`
and declares the expected stderr diagnostic with a comment line:

```cangjie
// expect-diagnostic: duplicate JSON name "a"
```

The harness `scripts/run_macro_compile_fail.py` compiles every fixture with the
daily `cjc` in single-file mode (`-Woff all --import-path target/release`),
asserts a non-zero exit code and that every declared fragment appears in the
compiler stderr, and fails the run if any fixture unexpectedly compiles or
misses its diagnostic.

## Running

From the repository root (after `cjpm build`):

```sh
python3 scripts/run_macro_compile_fail.py
```

The harness sources `$CANGJIE_SDK/daily/cangjie/envsetup.sh` (or reuses an
already-configured `CANGJIE_HOME`/`PATH`/`LD_LIBRARY_PATH`), writes all
compiler output to an isolated `/tmp` directory, and never touches `target/`
or the repository tree.

## Coverage

| Fixture | Rejection branch |
| --- | --- |
| `json_subtype_invalid.cj` | `@JsonSubtype` without a concrete type |
| `json_field_missing_type.cj` | field without explicit type |
| `json_duplicate_name.cj` | duplicate JSON name |
| `json_duplicate_alias.cj` | alias collides with a JSON name |
| `json_double_using.cj` | more than one `@JsonUsing` |
| `json_ctor_mismatch.cj` | constructor parameter without a JSON property |
| `json_immutable_no_ctor.cj` | immutable field without a constructor parameter |
| `json_enum_duplicate_name.cj` | duplicate enum wire name |
| `json_enum_multiple_name.cj` | multiple `@JsonName` on one enum constructor |
| `json_polymorphic_empty.cj` | `@JsonPolymorphic` without any `@JsonSubtype` |
| `json_polymorphic_duplicate_discriminator.cj` | duplicate polymorphic discriminator |
| `json_polymorphic_discriminator_conflict.cj` | discriminator equals a field name |
| `json_unsupported_decl.cj` | macro applied to a non-class/struct/enum declaration |
