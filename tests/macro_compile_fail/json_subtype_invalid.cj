package macro_compile_fail

import yjson.*
import yjson_macros.*

// expect-diagnostic: @JsonSubtype expects a wire name and concrete type

@JsonCodec
@JsonSubtype["dog"]
open class Animal {
    public let id: Int64
    public init(id: Int64) { this.id = id }
}
