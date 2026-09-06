package macro_compile_fail

import yjson.*
import yjson_macros.*

// expect-diagnostic: @JsonPolymorphic requires at least one @JsonSubtype[wireName, ConcreteType]

@JsonCodec
@JsonPolymorphic[discriminator: "kind"]
open class EmptyPolymorphic {
    public let id: Int64
    public init(id: Int64) { this.id = id }
}
