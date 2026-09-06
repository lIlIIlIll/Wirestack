package macro_compile_fail

import yjson.*
import yjson_macros.*

// expect-diagnostic: enum constructor `Payload` has multiple @JsonName annotations

@JsonCodec
enum MultipleEnumName {
    @JsonName["first"]
    @JsonName["second"]
    Payload(String)
}
