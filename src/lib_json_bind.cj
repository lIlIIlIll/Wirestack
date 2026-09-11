package yjson

import std.ast.*
import std.collection.*

// Public aliases used by caller-side macro expansion. They keep generated
// collection helpers independent of imports in the consuming source file.
public type YJsonArrayList<T> = ArrayList<T>
public type YJsonHashMap<K, V> = HashMap<K, V>

/**
 * Changes the written name and primary read name of a generated-codec field.
 *
 * Use @JsonName["wire_name"] with @JsonCodec. Names and aliases must be unique within the generated type.
 */
@Annotation
public class JsonName {
    /**
     * Wire field name.
     */
    public let value: String

    /**
     * Creates JsonName with the supplied values.
     *
     * @param value Wire field name.
     */
    public const init(value: String) {
        this.value = value
    }
}

/**
 * Excludes a field from generated JSON encoding and decoding.
 *
 * Apply @JsonIgnore to a field of an @JsonCodec type.
 */
@Annotation
public class JsonIgnore {
    /**
     * Creates JsonIgnore with the supplied values.
     */
    public const init() {}
}

/**
 * Writes null for a generated Option field whose value is None.
 *
 * Without this annotation, generated optional fields may be omitted when their value is None.
 */
@Annotation
public class JsonIncludeNull {
    /**
     * Creates JsonIncludeNull with the supplied values.
     */
    public const init() {}
}

/**
 * Adds a read-only alternative name for a generated-codec field.
 *
 * Use @JsonAlias["old_name"]; the annotation can be repeated. Encoding still uses the primary name, not an alias.
 */
@Annotation
public class JsonAlias {
    /**
     * Alternative field name accepted during decoding.
     */
    public let value: String

    /**
     * Creates JsonAlias with the supplied values.
     *
     * @param value Alternative field name accepted during decoding.
     */
    public const init(value: String) {
        this.value = value
    }
}

// Retained AST metadata emitted by @JsonUsing. Applications should use the
// macro rather than spelling this annotation directly.
/**
 * Retained source metadata for the @JsonUsing macro.
 *
 * Generated-code integration detail. Applications should write @JsonUsing[codecExpression] rather than construct this annotation directly.
 */
@Annotation
public class JsonUsingMetadata {
    /**
     * Retained source expression consumed by macro processing.
     */
    public let expression: String

    /**
     * Creates JsonUsingMetadata with the supplied values.
     *
     * @param expression Source expression retained for the corresponding macro.
     */
    public const init(expression: String) {
        this.expression = expression
    }
}

/**
 * Selects the discriminator member used for a declared polymorphic mapping.
 *
 * Use with @JsonCodec and @JsonSubtype declarations. The discriminator member defaults to type.
 */
@Annotation
public class JsonPolymorphic {
    /**
     * JSON member name used for subtype selection.
     */
    public let discriminator: String

    /**
     * Creates JsonPolymorphic with the supplied values.
     *
     * @param discriminator Object member used for subtype selection; defaults to type.
     */
    public const init(discriminator!: String = "type") {
        this.discriminator = discriminator
    }
}

// Retained AST metadata emitted by @JsonSubtype. Each expression contains a
// wire discriminator followed by a concrete subtype, for example
// `@JsonSubtype["dog", Dog]`.
/**
 * Retained source metadata for a @JsonSubtype mapping.
 *
 * Generated-code integration detail. Applications should write @JsonSubtype["dog", Dog] rather than construct this annotation directly.
 */
@Annotation
public class JsonSubtypeMetadata {
    /**
     * Retained source expression consumed by macro processing.
     */
    public let expression: String

    /**
     * Creates JsonSubtypeMetadata with the supplied values.
     *
     * @param expression Source expression retained for the corresponding macro.
     */
    public const init(expression: String) {
        this.expression = expression
    }
}
