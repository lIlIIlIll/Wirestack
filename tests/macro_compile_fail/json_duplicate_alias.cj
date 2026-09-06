package macro_compile_fail

import yjson.*
import yjson_macros.*

// expect-diagnostic: duplicate JSON name "legacy"

@JsonCodec
class DuplicateAlias {
    @JsonName["current"]
    @JsonAlias["legacy"]
    public let x: Int64
    @JsonName["legacy"]
    public let y: Int64

    public init(x: Int64, y: Int64) {
        this.x = x
        this.y = y
    }
}
