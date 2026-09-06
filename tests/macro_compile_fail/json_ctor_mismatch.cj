package macro_compile_fail

import yjson.*
import yjson_macros.*

// expect-diagnostic: constructor parameter `label` has no JSON property

@JsonCodec
class CtorMismatch {
    public let id: Int64

    public init(id: Int64, label: String) {
        this.id = id
    }
}
