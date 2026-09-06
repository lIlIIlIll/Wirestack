package macro_compile_fail

import yjson.*
import yjson_macros.*

// expect-diagnostic: polymorphic discriminator conflicts with JSON field "kind"

@JsonCodec
@JsonPolymorphic[discriminator: "kind"]
@JsonSubtype["dog", DogSubtype]
open class DiscriminatorConflict {
    @JsonName["kind"]
    public let kind: String

    public init(kind: String) {
        this.kind = kind
    }
}

@JsonCodec
class DogSubtype <: DiscriminatorConflict {
    public var barks: Bool = false
    public init(kind: String) { super(kind) }
}
