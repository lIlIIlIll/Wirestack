package yjson

import std.ast.*
import std.collection.*

// Public aliases used by caller-side macro expansion. They keep generated
// collection helpers independent of imports in the consuming source file.
public type YJsonArrayList<T> = ArrayList<T>
public type YJsonHashMap<K, V> = HashMap<K, V>

@Annotation
public class JsonName {
    public let value: String

    public const init(value: String) {
        this.value = value
    }
}

@Annotation
public class JsonIgnore {
    public const init() {}
}

@Annotation
public class JsonIncludeNull {
    public const init() {}
}

@Annotation
public class JsonAlias {
    public let value: String

    public const init(value: String) {
        this.value = value
    }
}

// Retained AST metadata emitted by @JsonUsing. Applications should use the
// macro rather than spelling this annotation directly.
@Annotation
public class JsonUsingMetadata {
    public let expression: String

    public const init(expression: String) {
        this.expression = expression
    }
}

@Annotation
public class JsonPolymorphic {
    public let discriminator: String

    public const init(discriminator!: String = "type") {
        this.discriminator = discriminator
    }
}

// Retained AST metadata emitted by @JsonSubtype. Each expression contains a
// wire discriminator followed by a concrete subtype, for example
// `@JsonSubtype["dog", Dog]`.
@Annotation
public class JsonSubtypeMetadata {
    public let expression: String

    public const init(expression: String) {
        this.expression = expression
    }
}
