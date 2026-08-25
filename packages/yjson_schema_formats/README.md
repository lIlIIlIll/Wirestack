# yjson_schema_formats

Optional JSON Schema format assertions for internationalized hostnames and
emails, URI/IRI references, and RFC 6570 URI Templates. The package uses the
system `libidn2` implementation for IDNA2008, Punycode round-trip, Bidi, and
ContextJ validation.

```cangjie
import yjson.*
import yjson_schema_formats.*

let formats = JsonSchemaFormatRegistry.withCoreFormats()
formats.install(StandardInternationalFormats())
let config = JsonSchemaConfig(
    formatMode: JsonSchemaFormatMode.Assertion,
    formats: formats
)
```

`Annotation` remains the core default and does not invoke any registered
format. `StrictAssertion` reports `unsupported_schema_format` for an unknown
format instead of silently accepting it. Configure the mutable registry before
sharing `JsonSchemaConfig`; do not register or replace formats concurrently
with validation.
