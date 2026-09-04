package macro_compile_fail

import yjson.*
import yjson_macros.*

// expect-diagnostic: duplicate JSON name "a"

@JsonCodec
class DuplicateName {
    @JsonName["a"]
    public let x: Int64
    @JsonName["a"]
    public let y: Int64

    public init(x: Int64, y: Int64) {
        this.x = x
        this.y = y
    }
}
