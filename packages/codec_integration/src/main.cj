package yjson_codec_integration

import yjson_all.*

private func require(condition: Bool, message: String): Unit {
    if (!condition) { throw Exception(message) }
}

private func requireJsonError(expectedCode: String, action: () -> Unit): Unit {
    try {
        action()
        throw Exception("expected JsonException with code ${expectedCode}")
    } catch (error: JsonException) {
        require(error.code == expectedCode, "expected ${expectedCode}, got ${error.code}")
    }
}

@JsonCodec
class ExternalUser {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        this.id = id
        this.name = name
    }
}

@JsonCodec
enum ExternalEvent {
    Ready | Renamed(String, Int64)
}

@JsonCodec
@JsonSubtype["dog", ExternalDog]
@JsonSubtype["cat", ExternalCat]
@JsonPolymorphic[discriminator: "kind"]
open class ExternalAnimal {
    public let id: Int64

    public init(id: Int64) {
        this.id = id
    }
}

@JsonCodec
class ExternalDog <: ExternalAnimal {
    public let bark: String

    public init(id: Int64, bark: String) {
        super(id)
        this.bark = bark
    }
}

@JsonCodec
class ExternalCat <: ExternalAnimal {
    public let lives: Int64

    public init(id: Int64, lives: Int64) {
        super(id)
        this.lives = lives
    }
}

main(): Unit {
    let userJson = YJson.toJson(ExternalUser(7, "Alice"))
    let user = YJson.fromJson<ExternalUser>(userJson)
    require(userJson == "{\"id\":7,\"name\":\"Alice\"}", "unexpected user JSON")
    require(user.id == 7 && user.name == "Alice", "user roundtrip failed")

    let userDecoder = YJson.fastDecoder(ExternalUserJson)
    let fastUser = userDecoder.decodeString(userJson)
    let fastUserBytes = userDecoder.decodeBytes(unsafe { userJson.rawData() })
    require(fastUser.id == 7 && fastUser.name == "Alice", "fast string decode failed")
    require(fastUserBytes.id == 7 && fastUserBytes.name == "Alice", "fast bytes decode failed")
    requireJsonError("unknown_field", { =>
        let _ = userDecoder.decodeString(
            "{\"id\":7,\"name\":\"Alice\",\"extra\":true}",
            config: JsonReadConfig(unknownFieldPolicy: JsonUnknownFieldPolicy.Reject)
        )
    })

    let eventJson = YJson.toJson(ExternalEvent.Renamed("Alice", 8))
    match (YJson.fromJson<ExternalEvent>(eventJson)) {
        case ExternalEvent.Renamed(name, revision) =>
            require(name == "Alice" && revision == 8, "associated enum roundtrip failed")
        case _ => throw Exception("associated enum constructor was not preserved")
    }

    let animal: ExternalAnimal = ExternalDog(41, "loud")
    let animalJson = YJson.toJson(animal)
    require(animalJson == "{\"kind\":\"dog\",\"id\":41,\"bark\":\"loud\"}", "unexpected polymorphic JSON")
    match (YJson.fromJson<ExternalAnimal>(animalJson)) {
        case dog: ExternalDog =>
            require(dog.id == 41 && dog.bark == "loud", "base-typed subtype data was not preserved")
        case _ => throw Exception("base-typed runtime subtype was not preserved")
    }
    match (YJson.fromJson<ExternalAnimal>(animalJson, config: JsonReadConfig(maxDepth: 1))) {
        case dog: ExternalDog =>
            require(dog.id == 41 && dog.bark == "loud", "scalar subtype fields consumed container depth")
        case _ => throw Exception("maxDepth=1 polymorphic subtype was not preserved")
    }

    let directDogJson = YJson.toJson(ExternalDog(42, "direct"))
    let directDog = YJson.fromJson<ExternalDog>(directDogJson)
    require(directDog.id == 42 && directDog.bark == "direct", "concrete subtype direct API failed")

    requireJsonError("missing_discriminator", { =>
        let _ = YJson.fromJson<ExternalAnimal>("{\"bark\":\"loud\"}")
    })
    requireJsonError("unknown_discriminator", { =>
        let _ = YJson.fromJson<ExternalAnimal>("{\"kind\":\"bird\"}")
    })
    requireJsonError("polymorphic_object_too_large", { =>
        let _ = YJson.fromJson<ExternalAnimal>(
            "{\"kind\":\"dog\",\"bark\":\"too large\"}",
            config: JsonReadConfig(maxPolymorphicObjectBytes: 8)
        )
    })

    println("codec integration checks passed")
}
