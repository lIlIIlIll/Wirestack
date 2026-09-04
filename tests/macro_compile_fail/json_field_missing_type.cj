package macro_compile_fail

import yjson.*
import yjson_macros.*

// expect-diagnostic: @JsonCodec requires an explicit type for `value`

@JsonCodec
class MissingType {
    public var value = 0

    public init() {}
}
