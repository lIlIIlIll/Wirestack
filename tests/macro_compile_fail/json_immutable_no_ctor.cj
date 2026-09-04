package macro_compile_fail

import yjson.*
import yjson_macros.*

// expect-diagnostic: immutable field `id` requires a constructor parameter

@JsonCodec
class ImmutableNoCtor {
    public let id: Int64 = 1
}
