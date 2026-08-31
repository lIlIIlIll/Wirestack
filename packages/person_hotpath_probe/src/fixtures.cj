package yjson_person_hotpath_probe

import yjson.*
import yjson_macros.*

import std.collection.*

@JsonCodec
class Address {
    @JsonName["street_name"]
    public var street: String
    public var zipcode: Int64

    public init(street: String, zipcode: Int64) {
        this.street = street
        this.zipcode = zipcode
    }
}

@JsonCodec
class Person {
    @JsonName["user_id"]
    public let id: Int64
    public var name: String
    public var age: Int32
    public var tags: ArrayList<String>
    public var scores: HashMap<String, Int64>
    public var address: Address
    @JsonIncludeNull
    public var nick: Option<String>

    public init(
        @JsonName["user_id"] id: Int64,
        name: String,
        age: Int32,
        tags: ArrayList<String>,
        scores: HashMap<String, Int64>,
        address: Address,
        nick: Option<String>
    ) {
        this.id = id
        this.name = name
        this.age = age
        this.tags = tags
        this.scores = scores
        this.address = address
        this.nick = nick
    }
}

@JsonCodec
class ProfileRecord {
    @JsonName["profile_id"]
    public let id: Int64
    public var alias: String = ""
    public var level: Int32 = 0

    public init(id: Int64) { this.id = id }
}

func samplePerson(): Person {
    let scores = HashMap<String, Int64>()
    scores.add("math", 95)
    scores.add("english", 88)
    Person(
        42,
        "Lin",
        28,
        ArrayList<String>(["cangjie", "json", "reflect"]),
        scores,
        Address("Nanshan Road", 518000),
        None
    )
}

func sampleProfileRecord(): ProfileRecord {
    let profile = ProfileRecord(7)
    profile.alias = "ops"
    profile.level = 3
    profile
}
