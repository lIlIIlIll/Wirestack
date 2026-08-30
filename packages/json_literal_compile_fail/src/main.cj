package yjson_json_literal_compile_fail

import yjson.*
import yjson_macros.*

main(): Unit {
    let _ = @Json({"same": 1, "\u{73}ame": 2})
}
