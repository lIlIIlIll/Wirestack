package macro_compile_fail

import yjson.*
import yjson_macros.*

// expect-diagnostic: @JsonUsing accepts exactly one codec expression

@JsonCodec
class DoubleUsing {
    @JsonUsing[JsonCodecs.int64]
    @JsonUsingMetadata[JsonCodecs.int64]
    public var value: Int64 = 0

    public init() {}
}
