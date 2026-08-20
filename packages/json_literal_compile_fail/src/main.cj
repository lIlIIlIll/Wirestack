package yjson_json_literal_compile_fail

import yjson_all.*

main(): Unit {
    let _ = @Json({"same": 1, "\u{73}ame": 2})
}
