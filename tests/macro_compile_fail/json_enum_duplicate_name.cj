package macro_compile_fail

import yjson.*
import yjson_macros.*

// expect-diagnostic: expected declaration, found Count

@JsonCodec
enum DuplicateEnumName {
    @JsonName["payload"]
    Text(String)
    @JsonName["payload"]
    Count(Int64)
}
