package macro_compile_fail

import yjson.*
import yjson_macros.*

// expect-diagnostic: @JsonCodec supports class, struct, and enum declarations

@JsonCodec
func unsupportedDeclaration(): Int64 { 0 }
