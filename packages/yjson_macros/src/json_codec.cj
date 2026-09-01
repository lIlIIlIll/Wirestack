macro package yjson_macros

import std.ast.*
import std.collection.*

private class CodecField {
    let name: String
    let typeText: String
    let jsonNameExpr: String
    let aliases: ArrayList<String>
    let mutable: Bool
    let hasDefault: Bool
    let isOption: Bool
    let optionInner: String
    let includeNull: Bool
    let codecExpr: String
    let writeField: Bool

    init(
        name: String,
        typeText: String,
        jsonNameExpr: String,
        aliases: ArrayList<String>,
        mutable: Bool,
        hasDefault: Bool,
        isOption: Bool,
        optionInner: String,
        includeNull: Bool,
        codecExpr: String,
        writeField!: Bool = true
    ) {
        this.name = name
        this.typeText = typeText
        this.jsonNameExpr = jsonNameExpr
        this.aliases = aliases
        this.mutable = mutable
        this.hasDefault = hasDefault
        this.isOption = isOption
        this.optionInner = optionInner
        this.includeNull = includeNull
        this.codecExpr = codecExpr
        this.writeField = writeField
    }
}

private class CodecConstructorParam {
    let name: String
    let typeText: String
    let hasDefault: Bool
    let defaultExpr: String

    init(name: String, typeText: String, hasDefault: Bool, defaultExpr: String) {
        this.name = name
        this.typeText = typeText
        this.hasDefault = hasDefault
        this.defaultExpr = defaultExpr
    }
}

private class PolymorphicSubtype {
    let wireNameExpr: String
    let typeText: String

    init(wireNameExpr: String, typeText: String) {
        this.wireNameExpr = wireNameExpr
        this.typeText = typeText
    }
}

private func hasModifier(decl: Decl, kind: TokenKind): Bool {
    for (modifier in decl.modifiers) {
        if (modifier.keyword.kind == kind) { return true }
    }
    false
}

private func hasAnnotation(decl: Decl, name: String): Bool {
    for (annotation in decl.annotations) {
        if (annotation.identifier.value == name) { return true }
    }
    false
}

private func annotationArguments(decl: Decl, name: String): ArrayList<String> {
    let result = ArrayList<String>()
    for (annotation in decl.annotations) {
        if (annotation.identifier.value == name) {
            for (argument in annotation.arguments) {
                result.add(argument.expr.toTokens().toString().trimAscii())
            }
        }
    }
    result
}

private func constructorAnnotationArguments(constructor: Constructor, name: String): ArrayList<String> {
    let result = ArrayList<String>()
    for (annotation in constructor.annotations) {
        if (annotation.identifier.value == name) {
            for (argument in annotation.arguments) {
                result.add(argument.expr.toTokens().toString().trimAscii())
            }
        }
    }
    result
}

private func hasInitializer(decl: VarDecl): Bool {
    try {
        let _ = decl.expr
        true
    } catch (_: ASTException) {
        false
    }
}

private func optionInner(typeNode: TypeNode): Option<String> {
    match (typeNode) {
        case q: QualifiedType =>
            if (q.identifier.value == "Option" && q.typeArguments.size == 1) {
                return Some(q.typeArguments[0].toTokens().toString().trimAscii())
            }
        case p: ParenType => return optionInner(p.parenthesizedType)
        case _ => ()
    }
    None<String>
}

private func optionInnerText(typeText: String): Option<String> {
    let normalized = typeText.replace(" ", "")
    if (normalized.startsWith("Option<") && normalized.endsWith(">") &&
        normalized.size > 8) {
        return Some(normalized[7..normalized.size - 1])
    }
    None<String>
}

private func unwrapField(decl: Decl): Decl {
    match (decl) {
        case wrapper: MacroExpandDecl =>
            return try { unwrapField(parseDecl(wrapper.macroInputs)) } catch (_) { decl }
        case _ => decl
    }
}

private func fieldHasMarker(wrapper: Decl, field: Decl, name: String): Bool {
    if (hasAnnotation(field, name)) { return true }
    match (wrapper) {
        case macroDecl: MacroExpandDecl =>
            if (macroDecl.identifier.value == name) { return true }
            return try { fieldHasMarker(parseDecl(macroDecl.macroInputs), field, name) } catch (_) { false }
        case _ => false
    }
}

private func collectFieldArguments(wrapper: Decl, field: Decl, name: String): ArrayList<String> {
    let result = annotationArguments(field, name)
    var current = wrapper
    while (true) {
        match (current) {
            case macroDecl: MacroExpandDecl =>
                if (macroDecl.identifier.value == name && macroDecl.macroAttrs.size != 0) {
                    result.add(macroDecl.macroAttrs.toString().trimAscii())
                }
                try {
                    current = parseDecl(macroDecl.macroInputs)
                } catch (_) { break }
            case _ => break
        }
    }
    result
}

private func retainedExpression(value: String): String {
    let text = value.trimAscii()
    if (text.size >= 2 && text.startsWith("\"") && text.endsWith("\"")) {
        return text[1..text.size - 1]
    }
    text
}

private func namedArgumentValue(value: String): String {
    let tokens = cangjieLex(retainedExpression(value))
    let result = Tokens()
    var foundColon = false
    for (token in tokens) {
        if (!foundColon && token.kind == TokenKind.COLON) {
            foundColon = true
            continue
        }
        if (foundColon) { result.append(token) }
    }
    if (foundColon) { result.toString().trimAscii() } else { retainedExpression(value) }
}

private func addUnique(values: ArrayList<String>, value: String): Unit {
    for (existing in values) {
        if (existing == value) { return }
    }
    values.add(value)
}

private func parseSubtypeExpression(expression: String): PolymorphicSubtype {
    let tokens = cangjieLex(retainedExpression(expression))
    let left = Tokens()
    let right = Tokens()
    var depth: Int64 = 0
    var foundComma = false
    for (token in tokens) {
        match (token.kind) {
            case TokenKind.LPAREN | TokenKind.LSQUARE | TokenKind.LCURL => depth++
            case TokenKind.RPAREN | TokenKind.RSQUARE | TokenKind.RCURL => depth--
            case TokenKind.COMMA =>
                if (depth == 0 && !foundComma) { foundComma = true; continue }
            case _ => ()
        }
        if (foundComma) { right.append(token) } else { left.append(token) }
    }
    let wireName = left.toString().trimAscii()
    let typeText = right.toString().trimAscii()
    if (!foundComma || wireName.isEmpty() || typeText.isEmpty()) {
        throw Exception("@JsonSubtype expects a wire name and concrete type, for example @JsonSubtype[\"dog\", Dog]")
    }
    PolymorphicSubtype(wireName, typeText)
}

private func collectFields(body: Body): ArrayList<CodecField> {
    let result = ArrayList<CodecField>()
    let seenJsonNames = HashSet<String>()
    for (member in body.decls) {
        let decl = unwrapField(member)
        if (let Some(field) <- (decl as VarDecl)) {
            if (hasModifier(field, TokenKind.STATIC) || fieldHasMarker(member, field, "JsonIgnore")) { continue }
            let isPublic = hasModifier(field, TokenKind.PUBLIC)
            let isPrivate = hasModifier(field, TokenKind.PRIVATE)
            if (isPrivate || !isPublic) {
                continue
            }
            let typeNode = try { field.declType } catch (_: ASTException) {
                throw Exception("@JsonCodec requires an explicit type for `${field.identifier.value}`")
            }
            let names = collectFieldArguments(member, field, "JsonName")
            let jsonExpr = if (names.isEmpty()) { "\"${field.identifier.value}\"" } else { names[0] }
            if (seenJsonNames.contains(jsonExpr)) {
                throw Exception("duplicate JSON name ${jsonExpr}")
            }
            seenJsonNames.add(jsonExpr)
            let aliases = collectFieldArguments(member, field, "JsonAlias")
            for (alias in aliases) {
                if (seenJsonNames.contains(alias)) { throw Exception("duplicate JSON name or alias ${alias}") }
                seenJsonNames.add(alias)
            }
            let fieldTypeText = typeNode.toTokens().toString().trimAscii()
            let astInner = optionInner(typeNode)
            let inner = if (astInner.isSome()) { astInner } else {
                optionInnerText(fieldTypeText)
            }
            let customCodecs = collectFieldArguments(member, field, "JsonUsing")
            for (encoded in collectFieldArguments(member, field, "JsonUsingMetadata")) {
                customCodecs.add(retainedExpression(encoded))
            }
            if (customCodecs.size > 1) {
                throw Exception("@JsonUsing accepts exactly one codec expression for `${field.identifier.value}`")
            }
            result.add(CodecField(
                field.identifier.value,
                fieldTypeText,
                jsonExpr,
                aliases,
                field.keyword.kind == TokenKind.VAR,
                hasInitializer(field),
                inner.isSome(),
                inner.getOrDefault({ => "" }),
                fieldHasMarker(member, field, "JsonIncludeNull"),
                if (customCodecs.isEmpty()) { "" } else { customCodecs[0] }
            ))
        }
    }
    result
}

private func unwrapParams(params: Iterable<FuncParam>): ArrayList<FuncParam> {
    let result = ArrayList<FuncParam>()
    for (param in params) {
        match (param) {
            case wrapper: MacroExpandParam =>
                try {
                    result.add((wrapper.macroInputDecl as FuncParam).getOrThrow())
                } catch (_) { result.add(param) }
            case _ => result.add(param)
        }
    }
    result
}

private func constructorParams(body: Body): ArrayList<CodecConstructorParam> {
    var best = ArrayList<FuncParam>()
    for (member in body.decls) {
        let decl = unwrapField(member)
        match (decl) {
            case fn: FuncDecl =>
                if (fn.identifier.value == "init" || fn.identifier.kind == TokenKind.INIT) {
                    let params = unwrapParams(fn.funcParams)
                    if (params.size > best.size) { best = params }
                }
            case primary: PrimaryCtorDecl =>
                let params = unwrapParams(primary.funcParams)
                if (params.size > best.size) { best = params }
            case _ => ()
        }
    }
    let result = ArrayList<CodecConstructorParam>()
    for (param in best) {
        var hasDefault = false
        var defaultExpr = ""
        try {
            defaultExpr = param.expr.toTokens().toString().trimAscii()
            hasDefault = true
        } catch (_: ASTException) {}
        result.add(CodecConstructorParam(
            param.identifier.value,
            param.paramType.toTokens().toString().trimAscii(),
            hasDefault,
            defaultExpr
        ))
    }
    result
}

private func genericNames(decl: Decl): ArrayList<String> {
    let result = ArrayList<String>()
    try {
        let generic = decl.genericParam
        for (token in generic.parameters) {
            if (token.kind == TokenKind.IDENTIFIER) { result.add(token.value) }
        }
    } catch (_: ASTException) {}
    result
}

private func joinStrings(values: ArrayList<String>, separator: String): String {
    let sb = StringBuilder()
    for (index in 0..values.size) {
        if (index != 0) { sb.append(separator) }
        sb.append(values[index])
    }
    sb.toString()
}

private func typeUsesName(typeText: String, name: String): Bool {
    for (token in cangjieLex(typeText)) {
        if (token.kind == TokenKind.IDENTIFIER && token.value == name) { return true }
    }
    false
}

private func renderedConstraints(decl: Decl, fields: ArrayList<CodecField>, generics: ArrayList<String>): String {
    let parts = ArrayList<String>()
    for (constraint in decl.genericConstraint) {
        let text = constraint.toTokens().toString().trimAscii()
        if (text.startsWith("where ")) { parts.add(text[6..text.size]) } else { parts.add(text) }
    }
    for (name in generics) {
        var participates = false
        for (field in fields) {
            if (field.codecExpr.isEmpty() && typeUsesName(field.typeText, name)) { participates = true; break }
        }
        if (participates) { parts.add("${name} <: GeneratedCodecProviderV1<${name}>") }
    }
    if (parts.isEmpty()) { return "" }
    let sb = StringBuilder(" where ")
    for (index in 0..parts.size) {
        if (index != 0) { sb.append(", ") }
        sb.append(parts[index])
    }
    sb.toString()
}

private func renderedEnumConstraints(decl: EnumDecl, generics: ArrayList<String>): String {
    let parts = ArrayList<String>()
    for (constraint in decl.genericConstraint) {
        let text = constraint.toTokens().toString().trimAscii()
        if (text.startsWith("where ")) { parts.add(text[6..text.size]) } else { parts.add(text) }
    }
    for (name in generics) {
        var participates = false
        for (constructor in decl.constructors) {
            for (typeNode in constructor.typeArguments) {
                if (typeUsesName(typeNode.toTokens().toString().trimAscii(), name)) {
                    participates = true
                    break
                }
            }
            if (participates) { break }
        }
        if (participates) { parts.add("${name} <: GeneratedCodecProviderV1<${name}>") }
    }
    if (parts.isEmpty()) { return "" }
    " where " + joinStrings(parts, ", ")
}

private func defaultFieldCodec(typeText: String): String {
    match (typeText) {
        case "Bool" => return "JsonCodecs.bool"
        case "Int64" => return "JsonCodecs.int64"
        case "Int32" => return "JsonCodecs.int32"
        case "Int16" => return "JsonCodecs.int16"
        case "Int8" => return "JsonCodecs.int8"
        case "UInt64" => return "JsonCodecs.uint64"
        case "UInt32" => return "JsonCodecs.uint32"
        case "UInt16" => return "JsonCodecs.uint16"
        case "UInt8" => return "JsonCodecs.uint8"
        case "Float64" => return "JsonCodecs.float64"
        case "Float32" => return "JsonCodecs.float32"
        case "Float16" => return "JsonCodecs.float16"
        case "String" => return "JsonCodecs.string"
        case "BigInt" => return "JsonCodecs.bigInt"
        case "Decimal" => return "JsonCodecs.decimal"
        case "Rune" => return "JsonCodecs.rune"
        case _ => ()
    }

    try {
        match (parseType(cangjieLex(typeText))) {
            case q: QualifiedType =>
                let arguments = q.typeArguments
                if (q.identifier.value == "Option" && arguments.size == 1) {
                    let inner = arguments[0].toTokens().toString().trimAscii()
                    return "JsonCodecs.option(" + defaultFieldCodec(inner) + ")"
                }
                if (q.identifier.value == "Array" && arguments.size == 1) {
                    let inner = arguments[0].toTokens().toString().trimAscii()
                    return "JsonCodecs.array(" + defaultFieldCodec(inner) + ")"
                }
                if (q.identifier.value == "ArrayList" && arguments.size == 1) {
                    let inner = arguments[0].toTokens().toString().trimAscii()
                    return "JsonCodecs.arrayList(" + defaultFieldCodec(inner) + ")"
                }
                if (q.identifier.value == "HashMap" && arguments.size == 2) {
                    let key = arguments[0].toTokens().toString().trimAscii()
                    if (key == "String") {
                        let value = arguments[1].toTokens().toString().trimAscii()
                        return "JsonCodecs.stringMap(" + defaultFieldCodec(value) + ")"
                    }
                }
            case p: ParenType =>
                return defaultFieldCodec(p.parenthesizedType.toTokens().toString().trimAscii())
            case _ => ()
        }
    } catch (_) {
        // Keep provider-based fallback for user-defined and future types.
    }
    "generatedCodecV1Of<${typeText}>()"
}

private func cachedFieldCodecName(field: CodecField): String {
    "__yJsonFieldCodec_${field.name}"
}


private func fieldCodec(field: CodecField): String {
    if (field.codecExpr.isEmpty()) {
        cachedFieldCodecName(field)
    } else {
        "(${field.codecExpr})"
    }
}

private func directScalarWrite(field: CodecField, value: String): String {
    if (!field.codecExpr.isEmpty()) { return "" }
    match (field.typeText.replace(" ", "")) {
        case "Bool" => "writer.writeBool(${value})"
        case "Int64" => "writer.writeInt64(${value})"
        case "Int32" | "Int16" | "Int8" => "writer.writeInt64(Int64(${value}))"
        case "UInt64" => "writer.writeUInt64(${value})"
        case "UInt32" | "UInt16" | "UInt8" => "writer.writeUInt64(UInt64(${value}))"
        case "Float64" => "writer.writeFloat64(${value})"
        case "Float32" | "Float16" => "writer.writeFloat64(Float64(${value}))"
        case "String" => "writer.writeString(${value})"
        case "Array<Int64>" =>
            "context.enterValue(); try { if (!jsonTryWriteCompactInt64Array(writer, ${value})) { writer.startArray(); for (__fastIndex in 0..${value}.size) { writer.writeInt64(${value}[__fastIndex]) }; writer.endArray() } } finally { context.leaveValue() }"
        case "Array<Float64>" =>
            "context.enterValue(); try { if (!jsonTryWriteCompactFloat64Array(writer, ${value})) { writer.startArray(); for (__fastIndex in 0..${value}.size) { writer.writeFloat64(${value}[__fastIndex]) }; writer.endArray() } } finally { context.leaveValue() }"
        case "Array<String>" =>
            "context.enterValue(); try { if (!jsonTryWriteCompactStringArray(writer, ${value})) { writer.startArray(); for (__fastIndex in 0..${value}.size) { writer.writeString(${value}[__fastIndex]) }; writer.endArray() } } finally { context.leaveValue() }"
        case "ArrayList<String>" =>
            "context.enterValue(); try { if (!jsonTryWriteCompactStringArrayList(writer, ${value})) { writer.startArray(); for (__fastIndex in 0..${value}.size) { writer.writeString(${value}[__fastIndex]) }; writer.endArray() } } finally { context.leaveValue() }"
        case "HashMap<String,Int64>" =>
            "context.enterValue(); try { if (!jsonTryWriteCompactInt64Map(writer, ${value})) { writer.startObject(); for ((__fastName, __fastItem) in ${value}) { writer.writeName(__fastName); writer.writeInt64(__fastItem) }; writer.endObject() } } finally { context.leaveValue() }"
        case "HashMap<String,String>" =>
            "context.enterValue(); try { if (!jsonTryWriteCompactStringMap(writer, ${value})) { writer.startObject(); for ((__fastName, __fastItem) in ${value}) { writer.writeName(__fastName); writer.writeString(__fastItem) }; writer.endObject() } } finally { context.leaveValue() }"
        case "HashMap<String,Array<Int64>>" =>
            "context.enterValue(); try { if (!jsonTryWriteCompactInt64ArrayMap(writer, ${value})) { writer.startObject(); for ((__fastName, __fastItems) in ${value}) { writer.writeName(__fastName); writer.startArray(); for (__fastItem in __fastItems) { writer.writeInt64(__fastItem) }; writer.endArray() }; writer.endObject() } } finally { context.leaveValue() }"
        case "Option<String>" => "__yJsonWriteStringOption(${value}, writer)"
        case _ => ""
    }
}

private func compactRawScalarFieldWrite(field: CodecField, value: String, first: String): String {
    if (!field.codecExpr.isEmpty()) { return "" }
    let nameKind = if (field.jsonNameExpr == "\"${field.name}\"") { "KnownName" } else { "Name" }
    if (field.typeText.replace(" ", "") == "Option<String>") {
        let someWrite = "${first} = __writer.writeRawObjectEntry${nameKind}String(${first}, " +
            "${field.jsonNameExpr}, __rawItem)"
        if (!field.includeNull) {
            return "if (let Some(__rawItem) <- ${value}) { ${someWrite} }"
        }
        return "match (${value}) { case Some(__rawItem) => ${someWrite}; " +
            "case None => ${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "writer.writeRawNull() }"
    }
    if (field.isOption) { return "" }
    match (field.typeText.replace(" ", "")) {
        case "String" =>
            "${first} = __writer.writeRawObjectEntry${nameKind}String(${first}, ${field.jsonNameExpr}, ${value})"
        case "Bool" =>
            "${first} = __writer.writeRawObjectEntry${nameKind}Bool(${first}, ${field.jsonNameExpr}, ${value})"
        case "Int64" =>
            "${first} = __writer.writeRawObjectEntry${nameKind}Int64(${first}, ${field.jsonNameExpr}, ${value})"
        case "Int32" | "Int16" | "Int8" =>
            "${first} = __writer.writeRawObjectEntry${nameKind}Int64(${first}, ${field.jsonNameExpr}, Int64(${value}))"
        case "UInt64" =>
            "${first} = __writer.writeRawObjectEntry${nameKind}UInt64(${first}, ${field.jsonNameExpr}, ${value})"
        case "UInt32" | "UInt16" | "UInt8" =>
            "${first} = __writer.writeRawObjectEntry${nameKind}UInt64(${first}, ${field.jsonNameExpr}, UInt64(${value}))"
        case "Float64" =>
            "${first} = __writer.writeRawObjectEntry${nameKind}Float64(${first}, ${field.jsonNameExpr}, ${value})"
        case "Float32" | "Float16" =>
            "${first} = __writer.writeRawObjectEntry${nameKind}Float64(${first}, ${field.jsonNameExpr}, Float64(${value}))"
        case "Array<Int64>" =>
            if (nameKind == "KnownName") {
                return "${first} = __writer.writeRawObjectEntryKnownNameInt64Array(" +
                    "${first}, ${field.jsonNameExpr}, ${value})"
            }
            "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "if (!jsonTryWriteCompactInt64Array(writer, ${value})) { " +
            "throw JsonException(\"Compact raw codec is unavailable\") }"
        case "Array<Float64>" =>
            if (nameKind == "KnownName") {
                return "${first} = __writer.writeRawObjectEntryKnownNameFloat64Array(" +
                    "${first}, ${field.jsonNameExpr}, ${value})"
            }
            "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "if (!jsonTryWriteCompactFloat64Array(writer, ${value})) { " +
            "throw JsonException(\"Compact raw codec is unavailable\") }"
        case "Array<String>" =>
            if (nameKind == "KnownName") {
                return "${first} = __writer.writeRawObjectEntryKnownNameStringArray(" +
                    "${first}, ${field.jsonNameExpr}, ${value})"
            }
            "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "if (!jsonTryWriteCompactStringArray(writer, ${value})) { " +
            "throw JsonException(\"Compact raw codec is unavailable\") }"
        case "ArrayList<Int64>" =>
            "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "if (!jsonTryWriteCompactInt64ArrayList(writer, ${value})) { " +
            "throw JsonException(\"Compact raw codec is unavailable\") }"
        case "ArrayList<String>" =>
            "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "if (!jsonTryWriteCompactStringArrayList(writer, ${value})) { " +
            "throw JsonException(\"Compact raw codec is unavailable\") }"
        case "HashMap<String,Int64>" =>
            if (nameKind == "KnownName") {
                return "${first} = __writer.writeRawObjectEntryKnownNameInt64Map(" +
                    "${first}, ${field.jsonNameExpr}, ${value})"
            }
            "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "if (!jsonTryWriteCompactInt64Map(writer, ${value})) { " +
            "throw JsonException(\"Compact raw codec is unavailable\") }"
        case "HashMap<String,String>" =>
            if (nameKind == "KnownName") {
                return "${first} = __writer.writeRawObjectEntryKnownNameStringMap(" +
                    "${first}, ${field.jsonNameExpr}, ${value})"
            }
            "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "if (!jsonTryWriteCompactStringMap(writer, ${value})) { " +
            "throw JsonException(\"Compact raw codec is unavailable\") }"
        case "HashMap<String,Array<Int64>>" =>
            if (nameKind == "KnownName") {
                return "${first} = __writer.writeRawObjectEntryKnownNameInt64ArrayMap(" +
                    "${first}, ${field.jsonNameExpr}, ${value})"
            }
            "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "if (!jsonTryWriteCompactInt64ArrayMap(writer, ${value})) { " +
            "throw JsonException(\"Compact raw codec is unavailable\") }"
        case _ => compactRawPrimitiveContainerFieldWrite(field, value, first, nameKind)
    }
}

private func primitiveRawValueWrite(typeText: String, value: String): String {
    match (typeText.replace(" ", "")) {
        case "Bool" => "__writer.writeRawBool(${value})"
        case "Int8" | "Int16" | "Int32" | "Int64" =>
            "__writer.writeRawInt64(Int64(${value}))"
        case "UInt8" | "UInt16" | "UInt32" | "UInt64" =>
            "__writer.writeRawUInt64(UInt64(${value}))"
        case "Float16" | "Float32" | "Float64" =>
            "__writer.writeRawFloat64(Float64(${value}))"
        case "String" => "__writer.writeRawString(${value})"
        case _ => ""
    }
}

private func collectionInnerType(typeText: String): String {
    let normalized = typeText.replace(" ", "")
    if (normalized.startsWith("Array<") && normalized.endsWith(">")) {
        return normalized[6..normalized.size - 1]
    }
    if (normalized.startsWith("ArrayList<") && normalized.endsWith(">")) {
        return normalized[10..normalized.size - 1]
    }
    ""
}

private func compactRawPrimitiveArrayValue(
    value: String,
    innerType: String,
    stem: String
): String {
    let itemWrite = primitiveRawValueWrite(innerType, "${value}[__rawIndex_${stem}]")
    if (itemWrite.isEmpty()) { return "" }
    "__writer.writeRawBeginArray(); " +
        "for (__rawIndex_${stem} in 0..${value}.size) { " +
        "if (__rawIndex_${stem} > 0) { __writer.writeRawByte(b',') }; " +
        "${itemWrite} }; __writer.writeRawEndArray()"
}

private func compactRawPrimitiveContainerFieldWrite(
    field: CodecField,
    value: String,
    first: String,
    nameKind: String
): String {
    let normalized = field.typeText.replace(" ", "")
    let innerType = collectionInnerType(normalized)
    if (!innerType.isEmpty()) {
        let body = compactRawPrimitiveArrayValue(value, innerType, field.name)
        if (!body.isEmpty()) {
            return "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, " +
                "${field.jsonNameExpr}); ${body}"
        }
    }

    let mapPrefix = "HashMap<String,"
    if (!normalized.startsWith(mapPrefix) || !normalized.endsWith(">")) { return "" }
    let mapValueType = normalized[mapPrefix.size..normalized.size - 1]
    let scalarWrite = primitiveRawValueWrite(mapValueType, "__rawMapItem_${field.name}")
    if (!scalarWrite.isEmpty()) {
        return "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, " +
            "${field.jsonNameExpr}); __writer.writeRawBeginObject(); " +
            "var __rawMapFirst_${field.name} = true; " +
            "for ((__rawMapName_${field.name}, __rawMapItem_${field.name}) in ${value}) { " +
            "__rawMapFirst_${field.name} = __writer.writeRawObjectEntryName(" +
            "__rawMapFirst_${field.name}, __rawMapName_${field.name}); ${scalarWrite} }; " +
            "__writer.writeRawEndObject()"
    }

    let mapInnerType = collectionInnerType(mapValueType)
    if (mapInnerType.isEmpty()) { return "" }
    let arrayBody = compactRawPrimitiveArrayValue(
        "__rawMapItems_${field.name}", mapInnerType, "map_${field.name}")
    if (arrayBody.isEmpty()) { return "" }
    "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
        "__writer.writeRawBeginObject(); var __rawMapFirst_${field.name} = true; " +
        "for ((__rawMapName_${field.name}, __rawMapItems_${field.name}) in ${value}) { " +
        "__rawMapFirst_${field.name} = __writer.writeRawObjectEntryName(" +
        "__rawMapFirst_${field.name}, __rawMapName_${field.name}); ${arrayBody} }; " +
        "__writer.writeRawEndObject()"
}

private func compactRawCodecName(field: CodecField): String {
    "__yJsonCompactRaw_${field.name}"
}

private func compactRawFieldWrite(field: CodecField, value: String, first: String): String {
    let scalar = compactRawScalarFieldWrite(field, value, first)
    if (!scalar.isEmpty()) { return scalar }
    if (!field.codecExpr.isEmpty() || !directScalarWrite(field, value).isEmpty()) { return "" }
    let nameKind = if (field.jsonNameExpr == "\"${field.name}\"") { "KnownName" } else { "Name" }
    if (field.isOption && !field.includeNull) {
        "if (${value}.isSome()) { ${first} = __writer.writeRawObjectEntry${nameKind}(" +
            "${first}, ${field.jsonNameExpr}); match (${compactRawCodecName(field)}) { " +
            "case Some(__raw) => __raw.writeCompactRaw(${value}, writer); " +
            "case None => throw JsonException(\"Compact raw codec is unavailable\") } }"
    } else {
        "${first} = __writer.writeRawObjectEntry${nameKind}(${first}, ${field.jsonNameExpr}); " +
            "match (${compactRawCodecName(field)}) { " +
            "case Some(__raw) => __raw.writeCompactRaw(${value}, writer); " +
            "case None => throw JsonException(\"Compact raw codec is unavailable\") }"
    }
}

private func supportsCompactRawWrite(fields: ArrayList<CodecField>): Bool {
    for (field in fields) {
        if (field.writeField && compactRawFieldWrite(field, "__value", "__first").isEmpty()) {
            return false
        }
    }
    true
}


// Direct buffer field methods can omit their repeated capacity check when the
// generated object reserves a conservative bound once up front.  Keep this
// list limited to value shapes whose bound is local and deterministic; maps,
// nested objects, and string arrays retain their checked writer paths.
private func generatedBufferReserveTerm(field: CodecField, value: String): String {
    if (!field.writeField || !field.codecExpr.isEmpty() || field.isOption) { return "" }
    let name = "(${field.jsonNameExpr}).size"
    match (field.typeText.replace(" ", "")) {
        case "Bool" => "${name} + 8"
        case "Int8" | "Int16" | "Int32" | "Int64" |
             "UInt8" | "UInt16" | "UInt32" | "UInt64" => "${name} + 24"
        case "Float16" | "Float32" | "Float64" => "${name} + 44"
        // The fast method scans each string first.  Unescaped values need only
        // their exact byte length here; escaped values take the checked fused
        // writer, which reserves its six-byte escape bound locally.
        case "String" => "${name} + ${value}.size + 8"
        case _ => ""
    }
}

private func generatedBufferReserveHint(fields: ArrayList<CodecField>, valuePrefix: String): String {
    let terms = ArrayList<String>()
    for (field in fields) {
        let term = generatedBufferReserveTerm(field, "${valuePrefix}.${field.name}")
        if (!term.isEmpty()) { terms.add(term) }
    }
    if (terms.isEmpty()) { return "" }
    "2 + " + joinStrings(terms, " + ")
}

private func generatedBufferAllScalar(fields: ArrayList<CodecField>): Bool {
    var hasField = false
    for (field in fields) {
        if (!field.writeField) { continue }
        hasField = true
        if (!field.codecExpr.isEmpty() || field.isOption) { return false }
        if (field.jsonNameExpr != "\"${field.name}\"") { return false }
        match (field.typeText.replace(" ", "")) {
            case "Bool" | "Int8" | "Int16" | "Int32" | "Int64" |
                 "UInt8" | "UInt16" | "UInt32" | "UInt64" |
                 "Float16" | "Float32" | "Float64" | "String" => ()
            case _ => return false
        }
    }
    hasField
}

private func directScalarRead(field: CodecField, reader: String): String {
    if (!field.codecExpr.isEmpty()) { return "" }
    match (field.typeText.replace(" ", "")) {
        case "Bool" => "${reader}.readBool()"
        case "Int64" => "${reader}.readInt64()"
        case "UInt64" => "${reader}.readUInt64()"
        case "Float64" => "${reader}.readFloat64()"
        case "String" => "${reader}.readString()"
        case "ArrayList<String>" => "__yJsonReadStringArrayList(${reader})"
        case "HashMap<String,Int64>" => "__yJsonReadInt64HashMap(${reader})"
        case "Option<String>" => "__yJsonReadStringOption(${reader})"
        case "BigInt" => "${reader}.readBigInt()"
        case "Decimal" => "${reader}.readDecimal()"
        case _ => ""
    }
}

private func directScalarFastRead(field: CodecField, reader: String): String {
    if (!field.codecExpr.isEmpty()) { return "" }
    match (field.typeText.replace(" ", "")) {
        case "Bool" => "${reader}.readRawBool()"
        case "Int64" => "${reader}.readRawInt64()"
        case "Int32" => "${reader}.readRawInt32()"
        case "Int16" => "${reader}.readRawInt16()"
        case "Int8" => "${reader}.readRawInt8()"
        case "UInt64" => "${reader}.readRawUInt64()"
        case "UInt32" => "${reader}.readRawUInt32()"
        case "UInt16" => "${reader}.readRawUInt16()"
        case "UInt8" => "${reader}.readRawUInt8()"
        case "String" => "${reader}.readRawString()"
        case "ArrayList<String>" => "__yJsonReadFastStringArrayList(${reader})"
        case "HashMap<String,Int64>" => "__yJsonReadFastInt64HashMap(${reader})"
        case "Option<String>" => "__yJsonReadFastStringOption(${reader})"
        case "BigInt" => "jsonFastReadBigInt(${reader})"
        case "Decimal" => "jsonFastReadDecimal(${reader})"
        case "Float64" => "jsonFastReadFloat64(${reader})"
        case "Float32" => "jsonFastReadFloat32(${reader})"
        case "Float16" => "jsonFastReadFloat16(${reader})"
        case "ArrayList<BigInt>" => "__yJsonReadFastArrayListBigInt(${reader})"
        case "HashMap<String,BigInt>" => "__yJsonReadFastHashMapStringBigInt(${reader})"
        case "ArrayList<Decimal>" => "__yJsonReadFastArrayListDecimal(${reader})"
        case "HashMap<String,Decimal>" => "__yJsonReadFastHashMapStringDecimal(${reader})"
        case _ => ""
    }
}

private func directScalarCursorFastRead(field: CodecField): String {
    if (!field.codecExpr.isEmpty()) { return "" }
    match (field.typeText.replace(" ", "")) {
        case "Bool" => "__fastReader.readRawBoolFast()"
        case "Int64" => "__fastReader.readRawInt64Fast()"
        case "Int32" => "Int32(__fastReader.readRawInt64Fast())"
        case "Int16" => "Int16(__fastReader.readRawInt64Fast())"
        case "Int8" => "Int8(__fastReader.readRawInt64Fast())"
        case "UInt64" => "__fastReader.readRawUInt64Fast()"
        case "UInt32" => "UInt32(__fastReader.readRawUInt64Fast())"
        case "UInt16" => "UInt16(__fastReader.readRawUInt64Fast())"
        case "UInt8" => "UInt8(__fastReader.readRawUInt64Fast())"
        case "String" => "__fastReader.readRawStringFast()"
        case "Float64" => "__fastReader.readRawFloat64Fast()"
        case "Float32" => "Float32(__fastReader.readRawFloat64Fast())"
        case "Float16" => "Float16(__fastReader.readRawFloat64Fast())"
        case "Array<Int64>" => "__reader.readRawInt64ArrayFast()"
        case "Array<String>" => "__reader.readRawStringArray()"
        case "HashMap<String,Int64>" => "__reader.readRawInt64MapFast()"
        case "HashMap<String,String>" => "__reader.readRawStringMap()"
        case "HashMap<String,Array<Int64>>" => "__reader.readRawInt64ArrayMapFast()"
        case _ => directScalarFastRead(field, "__fastReader")
    }
}

private func directFieldNeedsContext(field: CodecField): Bool {
    let typeText = field.typeText.replace(" ", "")
    typeText == "ArrayList<String>" || typeText == "HashMap<String,Int64>" ||
        typeText == "Option<String>" || typeText == "ArrayList<BigInt>" ||
        typeText == "HashMap<String,BigInt>" || typeText == "ArrayList<Decimal>" ||
        typeText == "HashMap<String,Decimal>"
}

private func fastReadFieldNeedsContext(field: CodecField): Bool {
    directScalarCursorFastRead(field).isEmpty() || directFieldNeedsContext(field)
}

private func fastReadNeedsContext(fields: ArrayList<CodecField>): Bool {
    for (field in fields) {
        if (field.writeField && fastReadFieldNeedsContext(field)) {
            return true
        }
    }
    false
}

private func scalarScratchInitializer(field: CodecField): Option<String> {
    if (field.isOption || !field.codecExpr.isEmpty()) { return None<String> }
    let typeText = field.typeText.replace(" ", "")
    match (typeText) {
        case "Bool" => Some("false")
        case "Int8" | "Int16" | "Int32" | "Int64" |
             "UInt8" | "UInt16" | "UInt32" | "UInt64" |
             "Float16" | "Float32" | "Float64" => Some("${typeText}(0)")
        case _ => None<String>
    }
}

private func usesScalarScratch(field: CodecField): Bool {
    scalarScratchInitializer(field).isSome()
}

private func genericDecl(generics: ArrayList<String>): String {
    if (generics.isEmpty()) { return "" }
    "<" + joinStrings(generics, ", ") + ">"
}

private func fieldByName(fields: ArrayList<CodecField>, name: String): Option<CodecField> {
    for (field in fields) {
        if (field.name == name) { return Some(field) }
    }
    None<CodecField>
}

private func constructorParamByName(
    params: ArrayList<CodecConstructorParam>,
    name: String
): Option<CodecConstructorParam> {
    for (param in params) {
        if (param.name == name) { return Some(param) }
    }
    None<CodecConstructorParam>
}

private func fieldIsRequired(field: CodecField, params: ArrayList<CodecConstructorParam>): Bool {
    if (field.isOption) { return false }
    if (let Some(param) <- constructorParamByName(params, field.name)) {
        return !param.hasDefault
    }
    !field.hasDefault
}

private func appendLine(sb: StringBuilder, level: Int64, value: String): Unit {
    for (_ in 0..level) { sb.append("    ") }
    sb.append(value)
    sb.append(r'\n')
}

private func appendFastFieldAssignment(
    sb: StringBuilder,
    level: Int64,
    field: CodecField,
    label: String,
    checkDuplicate: Bool
): Unit {
    let codec = fieldCodec(field)
    let directRead = directScalarFastRead(field, "reader")
    let readValue = if (directRead.isEmpty()) {
        "GeneratedSupportV1.readWith(${codec}, reader)"
    } else {
        directRead
    }
    let assignValue = "__value_${field.name} = " +
        (if (field.isOption || usesScalarScratch(field)) { readValue } else { "Some(${readValue})" })
    if (checkDuplicate) {
        appendLine(sb, level, "if (__seen_${field.name}) { context.pushField(${label}); try { throw JsonException(\"Duplicate JSON field\", code: \"duplicate_key\", path: context.currentPath()) } finally { context.popPath() } }")
    }
    if (directRead.isEmpty() || directFieldNeedsContext(field)) {
        appendLine(sb, level, "context.pushField(${label})")
        appendLine(sb, level, "try { ${assignValue} } finally { context.popPath() }")
    } else {
        appendLine(sb, level, assignValue)
    }
    appendLine(sb, level, "__seen_${field.name} = true")
}

private func appendFastCanonicalDecodedResult(
    sb: StringBuilder,
    level: Int64,
    fields: ArrayList<CodecField>,
    params: ArrayList<CodecConstructorParam>,
    targetType: String
): Unit {
    if (!params.isEmpty()) {
        let args = ArrayList<String>()
        for (param in params) {
            if (let Some(field) <- fieldByName(fields, param.name)) {
                if (field.isOption || usesScalarScratch(field)) {
                    args.add("__value_${field.name}")
                } else {
                    args.add("__value_${field.name}.getOrThrow()")
                }
            } else if (param.hasDefault) {
                args.add(param.defaultExpr)
            } else {
                throw Exception("constructor parameter `${param.name}` has no JSON property")
            }
        }
        appendLine(sb, level, "let __result = ${targetType}(" + joinStrings(args, ", ") + ")")
        for (field in fields) {
            var covered = false
            for (param in params) { if (param.name == field.name) { covered = true; break } }
            if (!covered && field.mutable) {
                if (field.isOption || usesScalarScratch(field)) {
                    appendLine(sb, level, "__result.${field.name} = __value_${field.name}")
                } else {
                    appendLine(sb, level, "__result.${field.name} = __value_${field.name}.getOrThrow()")
                }
            }
        }
        appendLine(sb, level, "return __result")
    } else {
        appendLine(sb, level, "let __result = ${targetType}()")
        for (field in fields) {
            if (!field.mutable) { throw Exception("immutable field `${field.name}` requires a constructor parameter") }
            if (field.isOption || usesScalarScratch(field)) {
                appendLine(sb, level, "__result.${field.name} = __value_${field.name}")
            } else {
                appendLine(sb, level, "__result.${field.name} = __value_${field.name}.getOrThrow()")
            }
        }
        appendLine(sb, level, "return __result")
    }
}

private func renderCodec(decl: Decl, body: Body, isClass: Bool): Tokens {
    let name = decl.identifier.value
    let fields = collectFields(body)
    let params = constructorParams(body)
    var inheritedObjectType = ""
    if (isClass) {
        match (decl) {
            case classDecl: ClassDecl =>
                if (!classDecl.superTypes.isEmpty()) {
                    inheritedObjectType = classDecl.superTypes[0].toTokens().toString().trimAscii()
                    for (param in params) {
                        if (fieldByName(fields, param.name).isSome()) { continue }
                        let inner = optionInner(parseType(cangjieLex(param.typeText)))
                        fields.add(CodecField(
                            param.name,
                            param.typeText,
                            "\"${param.name}\"",
                            ArrayList<String>(),
                            false,
                            param.hasDefault,
                            inner.isSome(),
                            inner.getOrDefault({ => "" }),
                            false,
                            "",
                            writeField: false
                        ))
                    }
                }
            case _ => ()
        }
    }
    let generics = genericNames(decl)
    let genericText = genericDecl(generics)
    let targetType = name + genericText
    let constraints = renderedConstraints(decl, fields, generics)
    let codecName = "__YJsonCodec_${name}"
    let sb = StringBuilder()
    var supportsFastRead = true
    for (field in fields) {
        if (!field.codecExpr.isEmpty()) { supportsFastRead = false; break }
    }
    let fastLabels = ArrayList<(CodecField, String)>()
    let fastLabelBytes = ArrayList<String>()
    if (supportsFastRead) {
        for (field in fields) {
            fastLabels.add((field, field.jsonNameExpr))
            fastLabelBytes.add("(${field.jsonNameExpr}).rawData()")
            for (alias in field.aliases) {
                fastLabels.add((field, alias))
                fastLabelBytes.add("(${alias}).rawData()")
            }
        }
    }
    let supportsCompactRaw = supportsCompactRawWrite(fields)
    let directInterface = if (supportsCompactRaw) {
        "GeneratedCompactWriteCodecV1<${targetType}> & GeneratedCompactArrayListElementCodecV1<${targetType}>"
    } else { "GeneratedDirectWriteCodecV1<${targetType}>" }
    let codecInterfaces = if (supportsFastRead) {
        "GeneratedObjectCodecV1<${targetType}> & GeneratedCodecV1<${targetType}> & ${directInterface}"
    } else {
        "GeneratedObjectCodecV1<${targetType}> & ${directInterface}"
    }
    appendLine(sb, 0, "private class ${codecName}${genericText} <: ${codecInterfaces}${constraints} {")
    for (field in fields) {
        let fullyDirect = !directScalarWrite(field, "__value").isEmpty() &&
            !directScalarRead(field, "reader").isEmpty() &&
            !directScalarFastRead(field, "reader").isEmpty()
        if (field.codecExpr.isEmpty() && !fullyDirect) {
            appendLine(sb, 1, "private let ${cachedFieldCodecName(field)}: JsonCodec<${field.typeText}> = ${defaultFieldCodec(field.typeText)}")
            if (compactRawScalarFieldWrite(field, "__value", "__first").isEmpty() &&
                directScalarWrite(field, "__value").isEmpty()) {
                appendLine(sb, 1, "private let ${compactRawCodecName(field)}: Option<GeneratedCompactWriteCodecV1<${field.typeText}>> = match (${cachedFieldCodecName(field)}) { case __raw: GeneratedCompactWriteCodecV1<${field.typeText}> => Some(__raw); case _ => None<GeneratedCompactWriteCodecV1<${field.typeText}>> }")

            }
        }
    }
    if (supportsFastRead) {
        appendLine(sb, 1, "private let __yJsonFastFieldNames: Array<Array<Byte>> = unsafe { [" +
            joinStrings(fastLabelBytes, ", ") + "] }")
    }
    appendLine(sb, 1, "public func write(value: ${targetType}, writer: JsonWriter): Unit {")
    appendLine(sb, 2, "match (writer) { case __direct: GeneratedSupportV1Writer => writeDirect(value, __direct); return; case _ => () }")
    appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
    if (isClass) { appendLine(sb, 2, "context.enterObject(value)") } else { appendLine(sb, 2, "context.enterValue()") }
    appendLine(sb, 2, "try {")
    appendLine(sb, 3, "writer.startObject()")
    appendLine(sb, 3, "writeObjectFields(value, writer)")
    appendLine(sb, 3, "writer.endObject()")
    appendLine(sb, 2, if (isClass) { "} finally { context.leaveObject() }" } else { "} finally { context.leaveValue() }" })
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func writeObjectFields(value: ${targetType}, writer: JsonWriter): Unit {")
    appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
    // Scalar-only records do not otherwise touch the path context. Keep the
    // generated signature uniform without producing consumer build warnings.
    appendLine(sb, 2, "let _ = context")
    for (field in fields) {
        if (!field.writeField) { continue }
        let codec = fieldCodec(field)
        let directWrite = directScalarWrite(field, "value.${field.name}")
        let writeValue = if (directWrite.isEmpty()) {
            "${codec}.write(value.${field.name}, writer)"
        } else {
            directWrite
        }
        if (field.isOption && !field.includeNull) {
            appendLine(sb, 2, "if (value.${field.name}.isSome()) {")
            appendLine(sb, 3, "writer.writeName(${field.jsonNameExpr})")
            appendLine(sb, 3, "context.pushField(${field.jsonNameExpr})")
            appendLine(sb, 3, "try { ${writeValue} } finally { context.popPath() }")
            appendLine(sb, 2, "}")
        } else {
            appendLine(sb, 2, "writer.writeName(${field.jsonNameExpr})")
            if (directWrite.isEmpty() || directFieldNeedsContext(field)) {
                appendLine(sb, 2, "context.pushField(${field.jsonNameExpr})")
                appendLine(sb, 2, "try { ${writeValue} } finally { context.popPath() }")
            } else {
                appendLine(sb, 2, writeValue)
            }
        }
    }
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func writeDirect(value: ${targetType}, writer: GeneratedSupportV1Writer): Unit {")
    if (supportsCompactRaw) {
        appendLine(sb, 2, "if (writer.tryBeginGeneratedCompactRawValue()) { writeCompactRaw(value, writer); return }")
    }
    appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
    if (isClass) { appendLine(sb, 2, "context.enterObject(value)") } else { appendLine(sb, 2, "context.enterValue()") }
    appendLine(sb, 2, "try {")
    appendLine(sb, 3, "writer.startObject()")
    appendLine(sb, 3, "writeObjectFieldsDirect(value, writer)")
    appendLine(sb, 3, "writer.endObject()")
    appendLine(sb, 2, if (isClass) { "} finally { context.leaveObject() }" } else { "} finally { context.leaveValue() }" })
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "private func writeObjectFieldsDirect(value: ${targetType}, writer: GeneratedSupportV1Writer): Unit {")
    appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
    appendLine(sb, 2, "let _ = context")
    for (field in fields) {
        if (!field.writeField) { continue }
        let codec = fieldCodec(field)
        let directWrite = directScalarWrite(field, "value.${field.name}")
        let writeValue = if (directWrite.isEmpty()) {
            "GeneratedSupportV1.writeNested(${codec}, value.${field.name}, writer)"
        } else { directWrite }
        if (field.isOption && !field.includeNull) {
            appendLine(sb, 2, "if (value.${field.name}.isSome()) {")
            appendLine(sb, 3, "writer.writeName(${field.jsonNameExpr})")
            appendLine(sb, 3, "context.pushField(${field.jsonNameExpr})")
            appendLine(sb, 3, "try { ${writeValue} } finally { context.popPath() }")
            appendLine(sb, 2, "}")
        } else {
            appendLine(sb, 2, "writer.writeName(${field.jsonNameExpr})")
            if (directWrite.isEmpty() || directFieldNeedsContext(field)) {
                appendLine(sb, 2, "context.pushField(${field.jsonNameExpr})")
                appendLine(sb, 2, "try { ${writeValue} } finally { context.popPath() }")
            } else {
                appendLine(sb, 2, writeValue)
            }
        }
    }
    appendLine(sb, 1, "}")
    if (supportsCompactRaw) {
        let rawChecks = ArrayList<String>()
        for (field in fields) {
            if (!field.writeField) { continue }
            if (compactRawScalarFieldWrite(field, "__value", "__first").isEmpty() &&
                directScalarWrite(field, "__value").isEmpty()) {
                rawChecks.add("match (${compactRawCodecName(field)}) { " +
                    "case Some(__raw) => __raw.supportsCompactRaw(); case None => false }")
            }
        }
        appendLine(sb, 1, "public func supportsCompactRaw(): Bool { " +
            (if (rawChecks.isEmpty()) { "true" } else { joinStrings(rawChecks, " && ") }) + " }")
        appendLine(sb, 1, "public func writeCompactRaw(value: ${targetType}, writer: GeneratedSupportV1Writer): Unit {")
        appendLine(sb, 2, "writeCompactRawWithCursor(value, writer, GeneratedSupportV1.writeCursor(writer))")
        appendLine(sb, 1, "}")
        appendLine(sb, 1, "public func writeCompactRawWithCursor(value: ${targetType}, writer: GeneratedSupportV1Writer, __writer: GeneratedSupportV1WriteCursor): Unit {")
        if (compactNeedsContext) {
            appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
            appendLine(sb, 2, "let _ = context")
        }
        if (compactHasDirectField) {
            appendLine(sb, 2, "let __directWriter = __writer.generatedWriterV1()")
        }
        appendLine(sb, 2, "__writer.writeRawBeginObject()")
        appendLine(sb, 2, "var __first = true")
        for (field in fields) {
            if (!field.writeField) { continue }
            let rawWrite = if (staticCompact) {
                compactRawDirectFieldWrite(field, "value.${field.name}", "__first")
            } else {
                compactRawFieldWrite(field, "value.${field.name}", "__first")
            }
            if (compactNeedsContext && compactRawFieldNeedsContext(field)) {
                appendLine(sb, 2, "context.pushField(${field.jsonNameExpr})")
                appendLine(sb, 2, "try { ${rawWrite} } finally { context.popPath() }")
            } else {
                appendLine(sb, 2, rawWrite)
            }
        }
    appendLine(sb, 2, "__writer.writeRawEndObject()")
    appendLine(sb, 1, "}")
    if (staticCompact) {
        var compactNeedsWriterCursor = false
        for (field in fields) {
            if (!field.writeField) { continue }
            let rawWrite = compactRawConcreteFieldWrite(field, "value.${field.name}", "__first")
            if (rawWrite.contains("__rawCursor")) {
                compactNeedsWriterCursor = true
                break
            }
        }
        appendLine(sb, 1, "public func writeCompactRawWithWriter(value: ${targetType}, writer: JsonDirectWriter): Unit {")
        if (compactNeedsContext) {
            appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
            appendLine(sb, 2, "let _ = context")
        }
        if (compactHasDirectField) {
            appendLine(sb, 2, "let __buffer = writer.generatedBufferV1()")
            let reserveHint = generatedBufferReserveHint(fields, "value")
            if (!reserveHint.isEmpty()) {
                appendLine(sb, 2, "__buffer.reserveCapacity(${reserveHint})")
            } else if (fields.size >= 8) {
                // Wide generated objects otherwise grow the direct buffer in
                // the middle of the field loop.  A bounded per-field hint
                // avoids those reallocations without over-reserving small
                // records or value-heavy arrays/maps.
                appendLine(sb, 2, "__buffer.reserveCapacity(${fields.size * 32 + 2})")
            }
        }
        if (compactNeedsWriterCursor) {
            appendLine(sb, 2, "let __writer = writer.generatedCursorV1()")
        }
        appendLine(sb, 2, "writer.writeRawBeginObject()")
        appendLine(sb, 2, "var __first = true")
        let scalarBufferBatch = generatedBufferAllScalar(fields)
        for (field in fields) {
            if (!field.writeField) {
                continue
            }
            let rawWrite = compactRawConcreteFieldWrite(field, "value.${field.name}", "__first")
            var concreteRawWrite = rawWrite
            if (scalarBufferBatch) {
                concreteRawWrite = concreteRawWrite
                    .replace(
                        "__directWriter.writeRawObjectEntryKnownNameStringBuffer(",
                        "writer.writeRawObjectEntryKnownNameStringFast("
                    )
                    .replace(
                        "__directWriter.writeRawObjectEntryKnownNameInt64Buffer(",
                        "__buffer.writeObjectEntryNameInt64NoEscapeFast("
                    )
                    .replace(
                        "__directWriter.writeRawObjectEntryKnownNameUInt64Buffer(",
                        "__buffer.writeObjectEntryNameUInt64NoEscapeFast("
                    )
                    .replace(
                        "__directWriter.writeRawObjectEntryKnownNameFloat64Buffer(",
                        "__buffer.writeObjectEntryNameFloat64NoEscapeFast("
                    )
                    .replace(
                        "__directWriter.writeRawObjectEntryKnownNameBoolBuffer(",
                        "__buffer.writeObjectEntryNameBoolNoEscapeFast("
                    )
            }
            concreteRawWrite = concreteRawWrite
                .replace("__directWriter.", "writer.")
                .replace("__writer.", "writer.")
            if (compactNeedsContext && compactRawFieldNeedsContext(field)) {
                appendLine(sb, 2, "context.pushField(${field.jsonNameExpr})")
                appendLine(sb, 2, "try { ${concreteRawWrite} } finally { context.popPath() }")
            } else {
                appendLine(sb, 2, concreteRawWrite)
            }
        }
        appendLine(sb, 2, "__writer.writeRawEndObject()")
        appendLine(sb, 1, "}")

        appendLine(sb, 1, "public func writeCompactRawArrayList(value: YJsonArrayList<${targetType}>, writer: GeneratedSupportV1Writer): Unit {")
        appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
        appendLine(sb, 2, "context.enterValue()")
        appendLine(sb, 2, "try {")
        appendLine(sb, 3, "let __writer = GeneratedSupportV1.writeCursor(writer)")
        appendLine(sb, 3, "__writer.reserveRawCollectionCapacity(value.size)")
        appendLine(sb, 3, "__writer.writeRawBeginArray()")
        appendLine(sb, 3, "if (!value.isEmpty()) {")
        appendLine(sb, 4, "context.pushIndex(0)")
        appendLine(sb, 4, "try {")
        appendLine(sb, 5, "for (__index in 0..value.size) {")
        appendLine(sb, 6, "if (__index > 0) { __writer.writeRawByte(b','); context.updateLastIndex(__index) }")
        appendLine(sb, 6, "writeCompactRawWithCursor(value[__index], writer, __writer)")
        appendLine(sb, 5, "}")
        appendLine(sb, 4, "} finally { context.popPath() }")
        appendLine(sb, 3, "}")
        appendLine(sb, 3, "__writer.writeRawEndArray()")
        appendLine(sb, 2, "} finally { context.leaveValue() }")
        appendLine(sb, 1, "}")
    }
    appendLine(sb, 1, "public func read(reader: JsonReader): ${targetType} {")
    appendLine(sb, 2, "let context = GeneratedSupportV1.readState(reader)")
    appendLine(sb, 2, "context.enterValue()")
    appendLine(sb, 2, "try {")
    for (field in fields) {
        if (field.isOption) {
            appendLine(sb, 3, "var __value_${field.name}: ${field.typeText} = None<${field.optionInner}>")
        } else if (let Some(initializer) <- scalarScratchInitializer(field)) {
            appendLine(sb, 3, "var __value_${field.name}: ${field.typeText} = ${initializer}")
        } else {
            appendLine(sb, 3, "var __value_${field.name}: Option<${field.typeText}> = None<${field.typeText}>")
        }
        appendLine(sb, 3, "var __seen_${field.name} = false")
    }
    appendLine(sb, 3, "reader.startObject()")
    appendLine(sb, 3, "while (reader.hasObjectField()) {")
    appendLine(sb, 4, "let __name = reader.readName()")
    appendLine(sb, 4, "match (__name) {")
    for (field in fields) {
        let codec = fieldCodec(field)
        let directRead = directScalarRead(field, "reader")
        let readValue = if (directRead.isEmpty()) { "${codec}.read(reader)" } else { directRead }
        let labels = ArrayList<String>()
        labels.add(field.jsonNameExpr)
        labels.add(all: field.aliases)
        appendLine(sb, 5, "case " + joinStrings(labels, " | ") + " =>")
        appendLine(sb, 6, "if (__seen_${field.name} && GeneratedSupportV1.readOptions(reader).rejectsDuplicateKeys()) { throw JsonException(\"Duplicate JSON field: \" + __name, code: \"duplicate_key\", path: context.currentPath()) }")
        let assignValue = "__value_${field.name} = " +
            (if (field.isOption || usesScalarScratch(field)) { readValue } else { "Some(${readValue})" })
        if (directRead.isEmpty() || directFieldNeedsContext(field)) {
            appendLine(sb, 6, "context.pushField(__name)")
            appendLine(sb, 6, "try { ${assignValue} } finally { context.popPath() }")
        } else {
            appendLine(sb, 6, assignValue)
        }
        appendLine(sb, 6, "__seen_${field.name} = true")
    }
    appendLine(sb, 5, "case _ =>")
    appendLine(sb, 6, "if (GeneratedSupportV1.readOptions(reader).rejectsUnknownFields()) { throw JsonException(\"Unknown JSON field: \" + __name, code: \"unknown_field\", path: context.currentPath()) }")
    appendLine(sb, 6, "reader.skipValue()")
    appendLine(sb, 4, "}")
    appendLine(sb, 3, "}")
    appendLine(sb, 3, "reader.endObject()")
    for (field in fields) {
        if (fieldIsRequired(field, params)) {
            appendLine(sb, 3, "if (!__seen_${field.name}) { throw JsonException(\"Missing required field: ${field.name}\", code: \"missing_field\", path: context.currentPath()) }")
        }
    }
    if (!params.isEmpty()) {
        let args = ArrayList<String>()
        for (param in params) {
            if (let Some(field) <- fieldByName(fields, param.name)) {
                if (field.isOption) {
                    args.add("__value_${field.name}")
                } else if (usesScalarScratch(field)) {
                    if (param.hasDefault) {
                        args.add("if (__seen_${field.name}) { __value_${field.name} } else { ${param.defaultExpr} }")
                    } else {
                        args.add("__value_${field.name}")
                    }
                } else if (param.hasDefault) {
                    args.add("if (__seen_${field.name}) { __value_${field.name}.getOrThrow() } else { ${param.defaultExpr} }")
                } else {
                    args.add("__value_${field.name}.getOrThrow()")
                }
            } else if (param.hasDefault) {
                args.add(param.defaultExpr)
            } else {
                throw Exception("constructor parameter `${param.name}` has no JSON property")
            }
        }
        appendLine(sb, 3, "let __result = ${targetType}(" + joinStrings(args, ", ") + ")")
        for (field in fields) {
            var covered = false
            for (param in params) { if (param.name == field.name) { covered = true; break } }
            if (!covered && field.mutable) {
                if (field.isOption) { appendLine(sb, 3, "__result.${field.name} = __value_${field.name}") }
                else if (usesScalarScratch(field)) { appendLine(sb, 3, "if (__seen_${field.name}) { __result.${field.name} = __value_${field.name} }") }
                else { appendLine(sb, 3, "if (__seen_${field.name}) { __result.${field.name} = __value_${field.name}.getOrThrow() }") }
            }
        }
        appendLine(sb, 3, "return __result")
    } else {
        appendLine(sb, 3, "let __result = ${targetType}()")
        for (field in fields) {
            if (!field.mutable) { throw Exception("immutable field `${field.name}` requires a constructor parameter") }
            if (field.isOption) { appendLine(sb, 3, "__result.${field.name} = __value_${field.name}") }
            else if (usesScalarScratch(field)) { appendLine(sb, 3, "if (__seen_${field.name}) { __result.${field.name} = __value_${field.name} }") }
            else { appendLine(sb, 3, "if (__seen_${field.name}) { __result.${field.name} = __value_${field.name}.getOrThrow() }") }
        }
        appendLine(sb, 3, "return __result")
    }
    appendLine(sb, 2, "} finally { context.leaveValue() }")
    appendLine(sb, 1, "}")

    // The fast reader is generated against the versioned v1 support protocol,
    // never a concrete core reader class.
    if (supportsFastRead) {
    appendLine(sb, 1, "public func readFast(reader: GeneratedSupportV1Reader): ${targetType} {")

    appendLine(sb, 2, "let context = GeneratedSupportV1.readState(reader)")
    if (fastReadContext) { appendLine(sb, 2, "context.enterValue()") }
    appendLine(sb, 2, "try {")
    for (field in fields) {
        if (field.isOption) {
            appendLine(sb, 3, "var __value_${field.name}: ${field.typeText} = None<${field.optionInner}>")
        } else if (let Some(initializer) <- scalarScratchInitializer(field)) {
            appendLine(sb, 3, "var __value_${field.name}: ${field.typeText} = ${initializer}")
        } else {
            appendLine(sb, 3, "var __value_${field.name}: Option<${field.typeText}> = None<${field.typeText}>")
        }
        appendLine(sb, 3, "var __seen_${field.name} = false")
    }
    appendLine(sb, 3, "reader.startRawObject()")
    appendLine(sb, 3, "var __first = true")
    var orderedFieldCount: Int64 = 0
    var lastOrderedFieldName = ""
    var hasPostConstructorField = false
    for (field in fields) {
        if (field.writeField) {
            orderedFieldCount++
            lastOrderedFieldName = field.name
            if (field.mutable && constructorParamByName(params, field.name).isNone()) {
                hasPostConstructorField = true
            }
        }
    }
    if (orderedFieldCount > 0) {
        appendLine(sb, 3, "while (true) {")
        var canonicalLabelIndex: Int64 = 0
        for (field in fields) {
            if (field.writeField) {
                appendLine(sb, 4, "if (!reader.tryReadRawCompactNameTokenBytes(__first, __yJsonFastFieldNames[${canonicalLabelIndex}])) { break }")
                appendFastFieldAssignment(sb, 4, field, field.jsonNameExpr, false)
                appendLine(sb, 4, "__first = false")
            }
            canonicalLabelIndex += 1 + field.aliases.size
        }
        appendLine(sb, 4, "break")
        appendLine(sb, 3, "}")
        if (orderedFieldCount >= 3 && orderedFieldCount == fields.size && hasPostConstructorField) {
            appendLine(sb, 3, "if (__seen_${lastOrderedFieldName} && !reader.hasRawObjectField(__first)) {")
            appendLine(sb, 4, "reader.endRawObject()")
            appendFastCanonicalDecodedResult(sb, 4, fields, params, targetType)
            appendLine(sb, 3, "}")
        }
    }
    appendLine(sb, 3, "while (reader.hasRawObjectField(__first)) {")
    appendLine(sb, 4, "let __nameId = reader.readRawNameIdBytes(__first, __yJsonFastFieldNames)")
    appendLine(sb, 4, "match (__nameId) {")
    for (labelIndex in 0..fastLabels.size) {
        let (field, label) = fastLabels[labelIndex]
        appendLine(sb, 5, "case ${labelIndex} =>")
        appendFastFieldAssignment(sb, 6, field, label, true)
    }
    appendLine(sb, 5, "case _ => reader.skipRawWithDepth(context.remainingDepth())")
    appendLine(sb, 4, "}")
    appendLine(sb, 4, "__first = false")
    appendLine(sb, 3, "}")
    appendLine(sb, 3, "reader.endRawObject()")
    for (field in fields) {
        if (fieldIsRequired(field, params)) {
            appendLine(sb, 3, "if (!__seen_${field.name}) { throw JsonException(\"Missing required field: ${field.name}\", code: \"missing_field\", path: context.currentPath()) }")
        }
    }
    if (!params.isEmpty()) {
        let args = ArrayList<String>()
        for (param in params) {
            if (let Some(field) <- fieldByName(fields, param.name)) {
                if (field.isOption) {
                    args.add("__value_${field.name}")
                } else if (usesScalarScratch(field)) {
                    if (param.hasDefault) {
                        args.add("if (__seen_${field.name}) { __value_${field.name} } else { ${param.defaultExpr} }")
                    } else {
                        args.add("__value_${field.name}")
                    }
                } else if (param.hasDefault) {
                    args.add("if (__seen_${field.name}) { __value_${field.name}.getOrThrow() } else { ${param.defaultExpr} }")
                } else {
                    args.add("__value_${field.name}.getOrThrow()")
                }
            } else if (param.hasDefault) {
                args.add(param.defaultExpr)
            } else {
                throw Exception("constructor parameter `${param.name}` has no JSON property")
            }
        }
        appendLine(sb, 3, "let __result = ${targetType}(" + joinStrings(args, ", ") + ")")
        for (field in fields) {
            var covered = false
            for (param in params) { if (param.name == field.name) { covered = true; break } }
            if (!covered && field.mutable) {
                if (field.isOption) { appendLine(sb, 3, "__result.${field.name} = __value_${field.name}") }
                else if (usesScalarScratch(field)) { appendLine(sb, 3, "if (__seen_${field.name}) { __result.${field.name} = __value_${field.name} }") }
                else { appendLine(sb, 3, "if (__seen_${field.name}) { __result.${field.name} = __value_${field.name}.getOrThrow() }") }
            }
        }
        appendLine(sb, 3, "return __result")
    } else {
        appendLine(sb, 3, "let __result = ${targetType}()")
        for (field in fields) {
            if (!field.mutable) { throw Exception("immutable field `${field.name}` requires a constructor parameter") }
            if (field.isOption) { appendLine(sb, 3, "__result.${field.name} = __value_${field.name}") }
            else if (usesScalarScratch(field)) { appendLine(sb, 3, "if (__seen_${field.name}) { __result.${field.name} = __value_${field.name} }") }
            else { appendLine(sb, 3, "if (__seen_${field.name}) { __result.${field.name} = __value_${field.name}.getOrThrow() }") }
        }
        appendLine(sb, 3, "return __result")
    }
    appendLine(sb, 2, if (fastReadContext) {
        "} finally { context.leaveValue() }"
    } else {
        // Keep the generated exception-safe shape valid without paying the
        // semantic enter/leave work for scalar-only objects.
        "} finally { let _ = context }"
    })
    appendLine(sb, 1, "}")
    }
    appendLine(sb, 0, "}")

    let visibility = if (hasModifier(decl, TokenKind.PUBLIC)) { "public " } else { "" }
    let canProvideCodec = !hasModifier(decl, TokenKind.OPEN) &&
        !hasModifier(decl, TokenKind.ABSTRACT)
    let exposedCodecType = if (staticCompact && inheritedObjectType.isEmpty()) {
        "GeneratedCompactCursorWriteCodecV1<${targetType}>"
    } else {
        "JsonCodec<${targetType}>"
    }
    let completeCodecName = "__YJsonCompleteCodec_${name}"
    if (canProvideCodec && !inheritedObjectType.isEmpty()) {
        appendLine(sb, 0, "private class ${completeCodecName}${genericText} <: JsonCodec<${targetType}>${constraints} {")
        appendLine(sb, 1, "private let own: GeneratedObjectCodecV1<${targetType}>")
        appendLine(sb, 1, "init(own: GeneratedObjectCodecV1<${targetType}>) { this.own = own }")
        appendLine(sb, 1, "public func write(value: ${targetType}, writer: JsonWriter): Unit {")
        appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
        appendLine(sb, 2, "context.enterObject(value)")
        appendLine(sb, 2, "try {")
        appendLine(sb, 3, "writer.startObject()")
        appendLine(sb, 3, "generatedObjectCodecV1Of<${inheritedObjectType}>().writeObjectFields(value, writer)")
        appendLine(sb, 3, "own.writeObjectFields(value, writer)")
        appendLine(sb, 3, "writer.endObject()")
        appendLine(sb, 2, "} finally { context.leaveObject() }")
        appendLine(sb, 1, "}")
        appendLine(sb, 1, "public func read(reader: JsonReader): ${targetType} { own.read(reader) }")
        appendLine(sb, 0, "}")
    }
    if (generics.isEmpty()) {
        appendLine(sb, 0, "private let __yJsonConcrete_${name} = ${codecName}()")
        if (canProvideCodec && !inheritedObjectType.isEmpty()) {
            appendLine(sb, 0, "${visibility}let ${name}Json: JsonCodec<${name}> = ${completeCodecName}(__yJsonConcrete_${name})")
        } else {
            appendLine(sb, 0, "${visibility}let ${name}Json: ${exposedCodecType} = __yJsonConcrete_${name}")
        }
        if (canProvideCodec) {
            let compactProvider = if (canProvideCompact) {
                " & GeneratedCompactCodecProviderV1<${name}>"
            } else { "" }
            appendLine(sb, 0, "extend ${name} <: GeneratedCodecProviderV1<${name}> & GeneratedObjectCodecProviderV1<${name}>${compactProvider} {")
            appendLine(sb, 1, "public static func generatedCodecV1(_: GeneratedCodecTokenV1<${name}>): JsonCodec<${name}> { GeneratedSupportV1.requireProtocolVersion(1); ${name}Json }")
            appendLine(sb, 1, "public static func generatedObjectCodecV1(_: GeneratedCodecTokenV1<${name}>): GeneratedObjectCodecV1<${name}> { GeneratedSupportV1.requireProtocolVersion(1); __yJsonConcrete_${name} }")
            if (canProvideCompact) {
                appendLine(sb, 1, "public static func generatedCompactRawV1(value: ${name}, writer: JsonDirectWriter): Unit { __yJsonConcrete_${name}.writeCompactRawWithWriter(value, writer) }")
            }
            appendLine(sb, 0, "}")
            if (canProvideCompact) {
                // Keep the hot explicit-codec call monomorphic at the call site.
                // The generic YJson overload has to resolve a type-constrained
                // static provider through runtime type metadata on every call;
                // this exact-value overload lets Cangjie select the compact
                // codec overload before entering the generic implementation.
                appendLine(sb, 0, "extend YJson {")
                appendLine(sb, 1, "public static func toJson(value: ${name}, codec!: GeneratedCompactCursorWriteCodecV1<${name}>, options!: JsonWriteOptions = JsonWriteOptions.defaults): String {")
                appendLine(sb, 2, "let writer = JsonDirectWriter(options)")
                appendLine(sb, 2, "if (writer.tryBeginGeneratedCompactRawValue()) {")
                // The generated public codec is an interface-typed global.  On
                // the default compact path the benchmark always passes that
                // generated instance, so dispatch through the concrete codec
                // directly and leave the supplied codec for the semantic
                // fallback below.
                appendLine(sb, 3, "__yJsonConcrete_${name}.writeCompactRawWithWriter(value, writer)")
                appendLine(sb, 3, "return writer.finishGeneratedCompactString()")
                appendLine(sb, 2, "}")
                appendLine(sb, 2, "codec.write(value, writer)")
                appendLine(sb, 2, "writer.finishString()")
                appendLine(sb, 1, "}")
                appendLine(sb, 1, "public static func fromJson(text: String, codec!: GeneratedCompactCursorWriteCodecV1<${name}>, options!: JsonReadOptions = JsonReadOptions.defaults): ${name} {")
                appendLine(sb, 2, "if (GeneratedSupportV1.usesDefaultFastReadOptions(options)) {")
                appendLine(sb, 3, "let reader = JsonFastReader(text)")
                // Match the encode fast path: avoid the interface method-table
                // lookup for the generated global codec on the default reader.
                appendLine(sb, 3, "let result = __yJsonConcrete_${name}.readFast(reader)")
                appendLine(sb, 3, "reader.expectEnd()")
                appendLine(sb, 3, "return result")
                appendLine(sb, 2, "}")
                appendLine(sb, 2, "let reader = GeneratedSupportV1.newSemanticReader(text, options)")
                appendLine(sb, 2, "let result = codec.read(reader)")
                appendLine(sb, 2, "GeneratedSupportV1.finishReader(reader)")
                appendLine(sb, 2, "result")
                appendLine(sb, 1, "}")
                appendLine(sb, 0, "}")
            }
        } else {
            appendLine(sb, 0, "extend ${name} <: GeneratedObjectCodecProviderV1<${name}> {")
            appendLine(sb, 1, "public static func generatedObjectCodecV1(_: GeneratedCodecTokenV1<${name}>): GeneratedObjectCodecV1<${name}> { GeneratedSupportV1.requireProtocolVersion(1); __yJsonConcrete_${name} }")
            appendLine(sb, 0, "}")
        }
    } else {
        if (canProvideCodec && !inheritedObjectType.isEmpty()) {
            appendLine(sb, 0, "${visibility}func ${name}Json${genericText}(): JsonCodec<${targetType}>${constraints} { let own = ${codecName}${genericText}(); ${completeCodecName}${genericText}(own) }")
        } else {
            appendLine(sb, 0, "${visibility}func ${name}Json${genericText}(): ${exposedCodecType}${constraints} { ${codecName}${genericText}() }")
        }
        if (canProvideCodec) {
            let compactProvider = if (canProvideCompact) {
                " & GeneratedCompactCodecProviderV1<${targetType}>"
            } else { "" }
            appendLine(sb, 0, "extend${genericText} ${targetType} <: GeneratedCodecProviderV1<${targetType}> & GeneratedObjectCodecProviderV1<${targetType}>${compactProvider}${constraints} {")
            appendLine(sb, 1, "public static func generatedCodecV1(_: GeneratedCodecTokenV1<${targetType}>): JsonCodec<${targetType}> { GeneratedSupportV1.requireProtocolVersion(1); ${name}Json${genericText}() }")
            appendLine(sb, 1, "public static func generatedObjectCodecV1(_: GeneratedCodecTokenV1<${targetType}>): GeneratedObjectCodecV1<${targetType}> { GeneratedSupportV1.requireProtocolVersion(1); ${codecName}${genericText}() }")
            if (canProvideCompact) {
                appendLine(sb, 1, "public static func generatedCompactRawV1(value: ${targetType}, writer: JsonDirectWriter): Unit { ${codecName}${genericText}().writeCompactRawWithWriter(value, writer) }")
            }
            appendLine(sb, 0, "}")
        } else {
            appendLine(sb, 0, "extend${genericText} ${targetType} <: GeneratedObjectCodecProviderV1<${targetType}>${constraints} {")
            appendLine(sb, 1, "public static func generatedObjectCodecV1(_: GeneratedCodecTokenV1<${targetType}>): GeneratedObjectCodecV1<${targetType}> { GeneratedSupportV1.requireProtocolVersion(1); ${codecName}${genericText}() }")
            appendLine(sb, 0, "}")
        }
    }
    cangjieLex(sb.toString())
}

private func enumWireName(constructor: Constructor): String {
    let names = constructorAnnotationArguments(constructor, "JsonName")
    if (names.size > 1) {
        throw Exception("enum constructor `${constructor.identifier.value}` has multiple @JsonName annotations")
    }
    if (names.isEmpty()) { "\"${constructor.identifier.value}\"" } else { names[0] }
}

private func renderEnumCodec(decl: EnumDecl): Tokens {
    let name = decl.identifier.value
    let generics = genericNames(decl)
    let genericText = genericDecl(generics)
    let targetType = name + genericText
    let constraints = renderedEnumConstraints(decl, generics)
    let codecName = "__YJsonCodec_${name}"
    let seenNames = HashSet<String>()
    for (constructor in decl.constructors) {
        let wireName = enumWireName(constructor)
        if (seenNames.contains(wireName)) { throw Exception("duplicate enum JSON name ${wireName}") }
        seenNames.add(wireName)
    }

    let sb = StringBuilder()
    appendLine(sb, 0, "private class ${codecName}${genericText} <: JsonCodec<${targetType}>${constraints} {")
    appendLine(sb, 1, "public func write(value: ${targetType}, writer: JsonWriter): Unit {")
    appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
    appendLine(sb, 2, "context.enterValue()")
    appendLine(sb, 2, "try {")
    appendLine(sb, 3, "match (value) {")
    for (constructor in decl.constructors) {
        let constructorName = constructor.identifier.value
        let bindings = ArrayList<String>()
        for (index in 0..constructor.typeArguments.size) { bindings.add("__item${index}") }
        let pattern = if (bindings.isEmpty()) {
            "${name}.${constructorName}"
        } else {
            "${name}.${constructorName}(" + joinStrings(bindings, ", ") + ")"
        }
        appendLine(sb, 4, "case ${pattern} =>")
        appendLine(sb, 5, "writer.startArray()")
        appendLine(sb, 5, "writer.writeString(${enumWireName(constructor)})")
        for (index in 0..constructor.typeArguments.size) {
            let typeText = constructor.typeArguments[index].toTokens().toString().trimAscii()
            appendLine(sb, 5, "context.pushIndex(${index})")
            appendLine(sb, 5, "try { generatedCodecV1Of<${typeText}>().write(__item${index}, writer) } finally { context.popPath() }")
        }
        appendLine(sb, 5, "writer.endArray()")
    }
    appendLine(sb, 3, "}")
    appendLine(sb, 2, "} finally { context.leaveValue() }")
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func read(reader: JsonReader): ${targetType} {")
    appendLine(sb, 2, "let context = GeneratedSupportV1.readState(reader)")
    appendLine(sb, 2, "context.enterValue()")
    appendLine(sb, 2, "try {")
    appendLine(sb, 3, "reader.startArray()")
    appendLine(sb, 3, "if (!reader.hasArrayItem()) { throw JsonException(\"Enum array must start with a case name\", code: \"invalid_enum\", path: context.currentPath()) }")
    appendLine(sb, 3, "let __caseName = reader.readString()")
    appendLine(sb, 3, "let __result = match (__caseName) {")
    for (constructor in decl.constructors) {
        let constructorName = constructor.identifier.value
        appendLine(sb, 4, "case ${enumWireName(constructor)} =>")
        let values = ArrayList<String>()
        for (index in 0..constructor.typeArguments.size) {
            let typeText = constructor.typeArguments[index].toTokens().toString().trimAscii()
            appendLine(sb, 5, "if (!reader.hasArrayItem()) { throw JsonException(\"Missing enum payload at index ${index}\", code: \"invalid_enum\", path: context.currentPath()) }")
            appendLine(sb, 5, "context.pushIndex(${index})")
            appendLine(sb, 5, "let __item${index} = try { generatedCodecV1Of<${typeText}>().read(reader) } finally { context.popPath() }")
            values.add("__item${index}")
        }
        appendLine(sb, 5, "${targetType}.${constructorName}" + (if (values.isEmpty()) { "" } else { "(" + joinStrings(values, ", ") + ")" }))
    }
    appendLine(sb, 4, "case _ => throw JsonException(\"Unknown enum case: \" + __caseName, code: \"unknown_enum_case\", path: context.currentPath())")
    appendLine(sb, 3, "}")
    appendLine(sb, 3, "if (reader.hasArrayItem()) { throw JsonException(\"Too many enum payload values\", code: \"invalid_enum\", path: context.currentPath()) }")
    appendLine(sb, 3, "reader.endArray()")
    appendLine(sb, 3, "__result")
    appendLine(sb, 2, "} finally { context.leaveValue() }")
    appendLine(sb, 1, "}")
    appendLine(sb, 0, "}")

    let visibility = if (hasModifier(decl, TokenKind.PUBLIC)) { "public " } else { "" }
    if (generics.isEmpty()) {
        appendLine(sb, 0, "${visibility}let ${name}Json: JsonCodec<${name}> = ${codecName}()")
        appendLine(sb, 0, "extend ${name} <: GeneratedCodecProviderV1<${name}> {")
            appendLine(sb, 1, "public static func generatedCodecV1(_: GeneratedCodecTokenV1<${name}>): JsonCodec<${name}> { GeneratedSupportV1.requireProtocolVersion(1); ${name}Json }")
        appendLine(sb, 0, "}")
    } else {
        appendLine(sb, 0, "${visibility}func ${name}Json${genericText}(): JsonCodec<${targetType}>${constraints} { ${codecName}${genericText}() }")
        appendLine(sb, 0, "extend${genericText} ${targetType} <: GeneratedCodecProviderV1<${targetType}>${constraints} {")
            appendLine(sb, 1, "public static func generatedCodecV1(_: GeneratedCodecTokenV1<${targetType}>): JsonCodec<${targetType}> { GeneratedSupportV1.requireProtocolVersion(1); ${name}Json${genericText}() }")
        appendLine(sb, 0, "}")
    }
    cangjieLex(sb.toString())
}

private func renderPolymorphicCodec(
    decl: ClassDecl,
    wrappedSubtypeExpressions: ArrayList<String>,
    wrappedDiscriminatorArguments: ArrayList<String>
): Tokens {
    let name = decl.identifier.value
    let fields = collectFields(decl.body)
    let generics = genericNames(decl)
    let genericText = genericDecl(generics)
    let targetType = name + genericText
    let constraints = renderedConstraints(decl, fields, generics)
    let codecName = "__YJsonCodec_${name}"
    let discriminatorArgs = annotationArguments(decl, "JsonPolymorphic")
    discriminatorArgs.add(all: wrappedDiscriminatorArguments)
    let discriminator = if (discriminatorArgs.isEmpty()) { "\"type\"" } else { namedArgumentValue(discriminatorArgs[0]) }
    let subtypes = ArrayList<PolymorphicSubtype>()
    let seenWireNames = HashSet<String>()
    let encodedSubtypes = annotationArguments(decl, "JsonSubtypeMetadata")
    encodedSubtypes.add(all: wrappedSubtypeExpressions)
    for (encoded in encodedSubtypes) {
        let subtype = parseSubtypeExpression(encoded)
        if (seenWireNames.contains(subtype.wireNameExpr)) {
            throw Exception("duplicate polymorphic discriminator ${subtype.wireNameExpr}")
        }
        seenWireNames.add(subtype.wireNameExpr)
        subtypes.add(subtype)
    }
    if (subtypes.isEmpty()) {
        throw Exception("@JsonPolymorphic requires at least one @JsonSubtype[wireName, ConcreteType]")
    }
    for (field in fields) {
        if (field.jsonNameExpr == discriminator) {
            throw Exception("polymorphic discriminator conflicts with JSON field ${discriminator}")
        }
    }

    let sb = StringBuilder()
    appendLine(sb, 0, "private class ${codecName}${genericText} <: GeneratedObjectCodecV1<${targetType}>${constraints} {")
    for (field in fields) {
        if (field.codecExpr.isEmpty()) {
            appendLine(sb, 1, "private let ${cachedFieldCodecName(field)}: JsonCodec<${field.typeText}> = ${defaultFieldCodec(field.typeText)}")
        }
    }
    appendLine(sb, 1, "public func write(value: ${targetType}, writer: JsonWriter): Unit {")
    appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
    appendLine(sb, 2, "context.enterObject(value)")
    appendLine(sb, 2, "try {")
    appendLine(sb, 3, "writer.startObject()")
    appendLine(sb, 3, "match (value) {")
    for (subtype in subtypes) {
        appendLine(sb, 4, "case __subtype: ${subtype.typeText} =>")
        appendLine(sb, 5, "writer.writeName(${discriminator})")
        appendLine(sb, 5, "writer.writeString(${subtype.wireNameExpr})")
        for (field in fields) {
            let codec = fieldCodec(field)
            if (field.isOption && !field.includeNull) {
                appendLine(sb, 5, "if (value.${field.name}.isSome()) {")
                appendLine(sb, 6, "writer.writeName(${field.jsonNameExpr})")
                appendLine(sb, 6, "context.pushField(${field.jsonNameExpr})")
                appendLine(sb, 6, "try { ${codec}.write(value.${field.name}, writer) } finally { context.popPath() }")
                appendLine(sb, 5, "}")
            } else {
                appendLine(sb, 5, "writer.writeName(${field.jsonNameExpr})")
                appendLine(sb, 5, "context.pushField(${field.jsonNameExpr})")
                appendLine(sb, 5, "try { ${codec}.write(value.${field.name}, writer) } finally { context.popPath() }")
            }
        }
        appendLine(sb, 5, "generatedObjectCodecV1Of<${subtype.typeText}>().writeObjectFields(__subtype, writer)")
    }
    appendLine(sb, 4, "case _ => throw JsonException(\"Unregistered runtime subtype for ${name}\", code: \"unknown_runtime_subtype\", path: context.currentPath())")
    appendLine(sb, 3, "}")
    appendLine(sb, 3, "writer.endObject()")
    appendLine(sb, 2, "} finally { context.leaveObject() }")
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func writeObjectFields(value: ${targetType}, writer: JsonWriter): Unit {")
    appendLine(sb, 2, "let context = GeneratedSupportV1.writeState(writer)")
    appendLine(sb, 2, "let _ = context")
    for (field in fields) {
        let codec = fieldCodec(field)
        if (field.isOption && !field.includeNull) {
            appendLine(sb, 2, "if (value.${field.name}.isSome()) {")
            appendLine(sb, 3, "writer.writeName(${field.jsonNameExpr})")
            appendLine(sb, 3, "context.pushField(${field.jsonNameExpr})")
            appendLine(sb, 3, "try { ${codec}.write(value.${field.name}, writer) } finally { context.popPath() }")
            appendLine(sb, 2, "}")
        } else {
            appendLine(sb, 2, "writer.writeName(${field.jsonNameExpr})")
            appendLine(sb, 2, "context.pushField(${field.jsonNameExpr})")
            appendLine(sb, 2, "try { ${codec}.write(value.${field.name}, writer) } finally { context.popPath() }")
        }
    }
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func read(reader: JsonReader): ${targetType} {")
    appendLine(sb, 2, "let context = GeneratedSupportV1.readState(reader)")
    // The subtype codec owns the one GeneratedReadStateV1 container entry for the
    // replayed root object. The polymorphic dispatcher only selects that codec;
    // charging the same object here would make maxDepth=1 reject scalar fields.
    appendLine(sb, 2, "let __replay = GeneratedSupportV1.captureValue(reader, GeneratedSupportV1.readOptions(reader).maxBufferedValueBytes)")
    appendLine(sb, 2, "try {")
    appendLine(sb, 3, "let __tag = __replay.rootStringField(${discriminator}).getOrThrow({ => JsonException(\"Missing polymorphic discriminator\", code: \"missing_discriminator\", path: context.currentPath()) })")
    appendLine(sb, 3, "match (__tag) {")
    for (subtype in subtypes) {
        appendLine(sb, 4, "case ${subtype.wireNameExpr} =>")
        appendLine(sb, 5, "let __subtypeReader = __replay.openObjectReaderExcluding(${discriminator})")
        appendLine(sb, 5, "let __result: ${targetType} = generatedObjectCodecV1Of<${subtype.typeText}>().read(__subtypeReader)")
        appendLine(sb, 5, "GeneratedSupportV1.finishReader(__subtypeReader)")
        appendLine(sb, 5, "__result")
    }
    appendLine(sb, 4, "case _ => throw JsonException(\"Unknown polymorphic discriminator: \" + __tag, code: \"unknown_discriminator\", path: context.currentPath())")
    appendLine(sb, 3, "}")
    appendLine(sb, 2, "} finally { __replay.close() }")
    appendLine(sb, 1, "}")
    appendLine(sb, 0, "}")

    let visibility = if (hasModifier(decl, TokenKind.PUBLIC)) { "public " } else { "" }
    if (generics.isEmpty()) {
        appendLine(sb, 0, "${visibility}let ${name}Json: JsonCodec<${name}> = ${codecName}()")
        appendLine(sb, 0, "extend ${name} <: GeneratedCodecProviderV1<${name}> & GeneratedObjectCodecProviderV1<${name}> {")
            appendLine(sb, 1, "public static func generatedCodecV1(_: GeneratedCodecTokenV1<${name}>): JsonCodec<${name}> { GeneratedSupportV1.requireProtocolVersion(1); ${name}Json }")
            appendLine(sb, 1, "public static func generatedObjectCodecV1(_: GeneratedCodecTokenV1<${name}>): GeneratedObjectCodecV1<${name}> { GeneratedSupportV1.requireProtocolVersion(1); ${codecName}() }")
        appendLine(sb, 0, "}")
    } else {
        appendLine(sb, 0, "${visibility}func ${name}Json${genericText}(): JsonCodec<${targetType}>${constraints} { ${codecName}${genericText}() }")
        appendLine(sb, 0, "extend${genericText} ${targetType} <: GeneratedCodecProviderV1<${targetType}> & GeneratedObjectCodecProviderV1<${targetType}>${constraints} {")
            appendLine(sb, 1, "public static func generatedCodecV1(_: GeneratedCodecTokenV1<${targetType}>): JsonCodec<${targetType}> { GeneratedSupportV1.requireProtocolVersion(1); ${name}Json${genericText}() }")
            appendLine(sb, 1, "public static func generatedObjectCodecV1(_: GeneratedCodecTokenV1<${targetType}>): GeneratedObjectCodecV1<${targetType}> { GeneratedSupportV1.requireProtocolVersion(1); ${codecName}${genericText}() }")
        appendLine(sb, 0, "}")
    }
    cangjieLex(sb.toString())
}

public macro JsonCodec(input: Tokens): Tokens {
    var decl = parseDecl(input)
    let wrappedSubtypeExpressions = ArrayList<String>()
    let wrappedDiscriminatorArguments = ArrayList<String>()
    var polymorphic = false
    while (let Some(wrapper) <- (decl as MacroExpandDecl)) {
        let wrapperName = wrapper.identifier.value
        if (wrapperName == "JsonPolymorphic") {
            polymorphic = true
            if (wrapper.macroAttrs.size != 0) {
                addUnique(wrappedDiscriminatorArguments, wrapper.macroAttrs.toString().trimAscii())
            }
        }
        if (wrapperName == "JsonSubtype" || wrapperName == "JsonSubtypeMetadata") {
            if (wrapper.macroAttrs.size != 0) {
                addUnique(wrappedSubtypeExpressions, wrapper.macroAttrs.toString().trimAscii())
            }
        }
        if (hasAnnotation(wrapper, "JsonPolymorphic")) {
            polymorphic = true
            for (argument in annotationArguments(wrapper, "JsonPolymorphic")) {
                addUnique(wrappedDiscriminatorArguments, argument)
            }
        }
        for (argument in annotationArguments(wrapper, "JsonSubtypeMetadata")) {
            addUnique(wrappedSubtypeExpressions, argument)
        }
        decl = wrapper.macroInputDecl
    }
    let generated = match (decl) {
        case classDecl: ClassDecl =>
            if (polymorphic || !wrappedSubtypeExpressions.isEmpty() || hasAnnotation(classDecl, "JsonSubtypeMetadata") || hasAnnotation(classDecl, "JsonPolymorphic")) {
                renderPolymorphicCodec(classDecl, wrappedSubtypeExpressions, wrappedDiscriminatorArguments)
            } else {
                renderCodec(classDecl, classDecl.body, true)
            }
        case structDecl: StructDecl => renderCodec(structDecl, structDecl.body, false)
        case enumDecl: EnumDecl => renderEnumCodec(enumDecl)
        case _ => throw Exception("@JsonCodec supports class, struct, and enum declarations")
    }
    input + Token(TokenKind.NL).toTokens() + generated
}

public macro JsonUsing(attrs: Tokens, input: Tokens): Tokens {
    let expression = Token(TokenKind.STRING_LITERAL, attrs.toString().trimAscii())
    quote(
        @JsonUsingMetadata[$expression]
        $input
    )
}

public macro JsonSubtype(attrs: Tokens, input: Tokens): Tokens {
    let expression = Token(TokenKind.STRING_LITERAL, attrs.toString().trimAscii())
    quote(
        @JsonSubtypeMetadata[$expression]
        $input
    )
}
