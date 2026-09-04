package macro_compile_fail

import yjson.*
import yjson_macros.*

// expect-diagnostic: duplicate polymorphic discriminator "kind"

@JsonCodec
@JsonPolymorphic[discriminator: "kind"]
@JsonSubtype["kind", FirstSubtype]
@JsonSubtype["kind", SecondSubtype]
open class DuplicateDiscriminator {
    public let id: Int64
    public init(id: Int64) { this.id = id }
}

@JsonCodec
class FirstSubtype <: DuplicateDiscriminator {
    public var extra: Int64 = 0
    public init(id: Int64) { super(id) }
}

@JsonCodec
class SecondSubtype <: DuplicateDiscriminator {
    public var extra: String = ""
    public init(id: Int64) { super(id) }
}
