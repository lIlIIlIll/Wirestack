package yjson_codec_integration

import std.unittest.*
import std.unittest.testmacro.*
import yjson.*
import yjson_macros.*

@JsonCodec
class ApiDocumentationRecord {
    @JsonName["user_id"]
    @JsonAlias["legacy_id"]
    public let id: Int64

    @JsonIncludeNull
    public let nickname: Option<String>

    @JsonIgnore
    public var cacheKey: String = "local"

    public init(id: Int64, nickname: Option<String>) {
        this.id = id
        this.nickname = nickname
    }
}

@Test
class ApiDocumentationContractConsumerTest {
    @TestCase
    func explicitCodecRoundTripsUtf8Bytes(): Unit {
        let value = "仓颉 JSON"
        let bytes = YJson.toJsonBytes(value, codec: JsonCodecs.string)
        @Expect(YJson.fromJson(bytes, codec: JsonCodecs.string), value)
        @Expect(YJson.fromJson(YJson.toJson(value, codec: JsonCodecs.string),
            codec: JsonCodecs.string), value)
    }

    @TestCase
    func fieldAnnotationsPreserveTheirDocumentedWireContract(): Unit {
        let value = YJson.fromJson<ApiDocumentationRecord>(
            "{\"legacy_id\":7,\"nickname\":null,\"unknown\":true}")
        @Expect(value.id, 7)
        @Expect(value.nickname.isNone(), true)
        @Expect(value.cacheKey, "local")
        let document = YJson.parseDocument(YJson.toJson(value))
        let root = document.root()
        @Expect(root.member("user_id").getOrThrow().asInt64(), 7)
        @Expect(root.member("legacy_id").isNone(), true)
        @Expect(root.member("cacheKey").isNone(), true)
        @Expect(root.member("nickname").getOrThrow().kind(), JsonKind.Null)
    }

    @TestCase
    func defaultTypedReadsRejectDuplicateKeys(): Unit {
        var rejected = false
        try {
            let _ = YJson.fromJson<ApiDocumentationRecord>(
                "{\"user_id\":1,\"user_id\":2,\"nickname\":null}")
        } catch (error: JsonException) {
            rejected = error.code == "duplicate_key"
        }
        @Expect(rejected, true)
    }

    @TestCase
    func completeDocumentReadsRejectTrailingNonWhitespace(): Unit {
        var rejected = false
        try {
            let _ = YJson.fromJson("1 2", codec: JsonCodecs.int64)
        } catch (error: JsonException) {
            rejected = !error.code.isEmpty()
        }
        @Expect(rejected, true)
    }

    @TestCase
    func materializeMustNotShareMutableStorage(): Unit {
        let document = YJson.parseDocument("{\"active\":false}")
        let copy = document.materialize().asObject()
        copy.put("active", JsonNode.boolean(true))
        @Expect(document.root().member("active").getOrThrow().asBool(), false)
        @Expect(YJson.fromJson(copy.get("active").getOrThrow().toJson(),
            codec: JsonCodecs.bool), true)
    }
}
