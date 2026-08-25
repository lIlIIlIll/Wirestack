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
    let staticGenerated: Bool

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
        writeField!: Bool = true,
        staticGenerated!: Bool = false
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
        this.staticGenerated = staticGenerated
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
            let explicit = fieldHasMarker(member, field, "JsonProperty")
            let isPublic = hasModifier(field, TokenKind.PUBLIC)
            let isProtected = hasModifier(field, TokenKind.PROTECTED)
            let isPrivate = hasModifier(field, TokenKind.PRIVATE)
            let isInternal = hasModifier(field, TokenKind.INTERNAL)
            if (isPrivate && explicit) {
                throw Exception("@JsonProperty cannot expose private field `${field.identifier.value}`")
            }
            if (isPrivate || (isProtected && !explicit) || (isInternal && !explicit) || (!isPublic && !explicit)) {
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
            let inner = optionInner(typeNode)
            let customCodecs = collectFieldArguments(member, field, "JsonUsing")
            for (encoded in collectFieldArguments(member, field, "JsonUsingMetadata")) {
                customCodecs.add(retainedExpression(encoded))
            }
            if (customCodecs.size > 1) {
                throw Exception("@JsonUsing accepts exactly one codec expression for `${field.identifier.value}`")
            }
            let staticGenerated = fieldHasMarker(member, field, "JsonStatic") ||
                fieldHasMarker(member, field, "JsonStaticMetadata")
            if (staticGenerated && !customCodecs.isEmpty()) {
                throw Exception("@JsonStatic cannot be combined with @JsonUsing on `${field.identifier.value}`")
            }
            let fieldTypeText = typeNode.toTokens().toString().trimAscii()
            if (staticGenerated && fieldTypeText.contains("<")) {
                throw Exception("@JsonStatic currently accepts a concrete non-generic @JsonCodec type on `${field.identifier.value}`")
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
                if (customCodecs.isEmpty()) { "" } else { customCodecs[0] },
                staticGenerated: staticGenerated
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
        if (participates) { parts.add("${name} <: JsonCodecProvider") }
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
        if (participates) { parts.add("${name} <: JsonCodecProvider") }
    }
    if (parts.isEmpty()) { return "" }
    " where " + joinStrings(parts, ", ")
}

private func defaultFieldCodec(typeText: String): String {
    match (typeText) {
        case "Bool" => return "BoolJson"
        case "Int64" => return "Int64Json"
        case "Int32" => return "Int32Json"
        case "Int16" => return "Int16Json"
        case "Int8" => return "Int8Json"
        case "UInt64" => return "UInt64Json"
        case "UInt32" => return "UInt32Json"
        case "UInt16" => return "UInt16Json"
        case "UInt8" => return "UInt8Json"
        case "Float64" => return "Float64Json"
        case "Float32" => return "Float32Json"
        case "Float16" => return "Float16Json"
        case "String" => return "StringJson"
        case "DateTime" => return "DateTimeJson"
        case "BigInt" => return "BigIntJson"
        case "Decimal" => return "DecimalJson"
        case "Rune" => return "RuneJson"
        case _ => ()
    }

    try {
        match (parseType(cangjieLex(typeText))) {
            case q: QualifiedType =>
                let arguments = q.typeArguments
                if (q.identifier.value == "Option" && arguments.size == 1) {
                    let inner = arguments[0].toTokens().toString().trimAscii()
                    if (inner == "String") { return "YJson.stringOptionCodec()" }
                    return "YJson.optionCodec(" + defaultFieldCodec(inner) + ")"
                }
                if (q.identifier.value == "Array" && arguments.size == 1) {
                    let inner = arguments[0].toTokens().toString().trimAscii()
                    return "YJson.arrayCodec(" + defaultFieldCodec(inner) + ")"
                }
                if (q.identifier.value == "ArrayList" && arguments.size == 1) {
                    let inner = arguments[0].toTokens().toString().trimAscii()
                    if (inner == "Int64") { return "YJson.int64ArrayListCodec()" }
                    if (inner == "String") { return "YJson.stringArrayListCodec()" }
                    return "YJson.arrayListCodec(" + defaultFieldCodec(inner) + ")"
                }
                if (q.identifier.value == "HashMap" && arguments.size == 2) {
                    let key = arguments[0].toTokens().toString().trimAscii()
                    if (key == "String") {
                        let value = arguments[1].toTokens().toString().trimAscii()
                        if (value == "Int64") { return "YJson.int64HashMapCodec()" }
                        return "YJson.hashMapCodec(" + defaultFieldCodec(value) + ")"
                    }
                }
            case p: ParenType =>
                return defaultFieldCodec(p.parenthesizedType.toTokens().toString().trimAscii())
            case _ => ()
        }
    } catch (_) {
        // Keep provider-based fallback for user-defined and future types.
    }
    "jsonCodecOf<${typeText}>()"
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
        case "ArrayList<String>" =>
            "context.enterValue(); try { if (!jsonTryWriteCompactStringArrayList(writer, ${value})) { writer.startArray(); for (__fastItem in ${value}) { writer.writeString(__fastItem) }; writer.endArray() } } finally { context.leaveValue() }"
        case "HashMap<String,Int64>" =>
            "context.enterValue(); try { if (!jsonTryWriteCompactInt64Map(writer, ${value})) { writer.startObject(); for ((__fastName, __fastItem) in ${value}) { writer.writeName(__fastName); writer.writeInt64(__fastItem) }; writer.endObject() } } finally { context.leaveValue() }"
        case "Option<String>" => "__yJsonWriteStringOption(${value}, writer, context)"
        case _ => ""
    }
}

private func compactRawFieldWrite(field: CodecField, value: String, first: String): String {
    if (!field.codecExpr.isEmpty() || field.staticGenerated || field.isOption) { return "" }
    match (field.typeText.replace(" ", "")) {
        case "String" =>
            "${first} = jsonWriteGeneratedCompactObjectEntryString(writer, ${first}, ${field.jsonNameExpr}, ${value})"
        case "Bool" =>
            "${first} = jsonWriteGeneratedCompactObjectEntryBool(writer, ${first}, ${field.jsonNameExpr}, ${value})"
        case "Int64" =>
            "${first} = jsonWriteGeneratedCompactObjectEntryInt64(writer, ${first}, ${field.jsonNameExpr}, ${value})"
        case "Int32" | "Int16" | "Int8" =>
            "${first} = jsonWriteGeneratedCompactObjectEntryInt64(writer, ${first}, ${field.jsonNameExpr}, Int64(${value}))"
        case _ => ""
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

private func directScalarRead(field: CodecField, reader: String): String {
    if (!field.codecExpr.isEmpty()) { return "" }
    match (field.typeText.replace(" ", "")) {
        case "Bool" => "${reader}.readBool()"
        case "Int64" => "${reader}.readInt64()"
        case "UInt64" => "${reader}.readUInt64()"
        case "Float64" => "${reader}.readFloat64()"
        case "String" => "${reader}.readString()"
        case "ArrayList<String>" => "__yJsonReadStringArrayList(${reader}, context)"
        case "HashMap<String,Int64>" => "__yJsonReadInt64HashMap(${reader}, context)"
        case "Option<String>" => "__yJsonReadStringOption(${reader}, context)"
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
        case "ArrayList<String>" => "__yJsonReadFastStringArrayList(${reader}, context)"
        case "HashMap<String,Int64>" => "__yJsonReadFastInt64HashMap(${reader}, context)"
        case "Option<String>" => "__yJsonReadFastStringOption(${reader}, context)"
        case "DateTime" => "jsonFastReadRfc3339DateTime(${reader})"
        case "BigInt" => "jsonFastReadBigInt(${reader})"
        case "Decimal" => "jsonFastReadDecimal(${reader})"
        case "Float64" => "jsonFastReadFloat64(${reader})"
        case "Float32" => "jsonFastReadFloat32(${reader})"
        case "Float16" => "jsonFastReadFloat16(${reader})"
        case "ArrayList<DateTime>" => "__yJsonReadFastArrayListRfc3339DateTime(${reader}, context)"
        case "HashMap<String,DateTime>" => "__yJsonReadFastHashMapStringRfc3339DateTime(${reader}, context)"
        case "ArrayList<BigInt>" => "__yJsonReadFastArrayListBigInt(${reader}, context)"
        case "HashMap<String,BigInt>" => "__yJsonReadFastHashMapStringBigInt(${reader}, context)"
        case "ArrayList<Decimal>" => "__yJsonReadFastArrayListDecimal(${reader}, context)"
        case "HashMap<String,Decimal>" => "__yJsonReadFastHashMapStringDecimal(${reader}, context)"
        case _ => ""
    }
}

private func directFieldNeedsContext(field: CodecField): Bool {
    let typeText = field.typeText.replace(" ", "")
    typeText == "ArrayList<String>" || typeText == "HashMap<String,Int64>" ||
        typeText == "Option<String>" || typeText == "ArrayList<DateTime>" ||
        typeText == "HashMap<String,DateTime>" || typeText == "ArrayList<BigInt>" ||
        typeText == "HashMap<String,BigInt>" || typeText == "ArrayList<Decimal>" ||
        typeText == "HashMap<String,Decimal>"
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
    label: String
): Unit {
    let codec = fieldCodec(field)
    let directRead = directScalarFastRead(field, "reader")
    let readValue = if (field.staticGenerated) {
        "__yJsonReadFast_${field.typeText}(reader, context)"
    } else if (directRead.isEmpty()) {
        "readJsonFastWith(${codec}, reader, context)"
    } else {
        directRead
    }
    let assignValue = "__value_${field.name} = " +
        (if (field.isOption || usesScalarScratch(field)) { readValue } else { "Some(${readValue})" })
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
    if (isClass) {
        match (decl) {
            case classDecl: ClassDecl =>
                if (!classDecl.superTypes.isEmpty()) {
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
    let directInterface = if (supportsCompactRaw) { "JsonCompactRawCodec<${targetType}>" } else { "JsonDirectWriteCodec<${targetType}>" }
    let codecInterfaces = if (supportsFastRead) {
        "JsonObjectCodec<${targetType}> & JsonFastCodec<${targetType}> & JsonFastDecoder<${targetType}> & ${directInterface}"
    } else {
        "JsonObjectCodec<${targetType}> & ${directInterface}"
    }
    appendLine(sb, 0, "private class ${codecName}${genericText} <: ${codecInterfaces}${constraints} {")
    for (field in fields) {
        let fullyDirect = !directScalarWrite(field, "__value").isEmpty() &&
            !directScalarRead(field, "reader").isEmpty() &&
            !directScalarFastRead(field, "reader").isEmpty()
        if (field.codecExpr.isEmpty() && !field.staticGenerated && !fullyDirect) {
            appendLine(sb, 1, "private let ${cachedFieldCodecName(field)}: JsonCodec<${field.typeText}> = ${defaultFieldCodec(field.typeText)}")
        }
    }
    if (supportsFastRead) {
        appendLine(sb, 1, "private let __yJsonFastFieldNames: Array<Array<Byte>> = unsafe { [" +
            joinStrings(fastLabelBytes, ", ") + "] }")
    }
    appendLine(sb, 1, "public func write(value: ${targetType}, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {")
    appendLine(sb, 2, "match (writer) { case __direct: JsonDirectWriter => writeDirect(value, __direct, context); return; case _ => () }")
    if (isClass) { appendLine(sb, 2, "context.enterObject(value)") } else { appendLine(sb, 2, "context.enterValue()") }
    appendLine(sb, 2, "try {")
    appendLine(sb, 3, "writer.startObject()")
    appendLine(sb, 3, "writeObjectFields(value, writer, context)")
    appendLine(sb, 3, "writer.endObject()")
    appendLine(sb, 2, if (isClass) { "} finally { context.leaveObject() }" } else { "} finally { context.leaveValue() }" })
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func writeObjectFields(value: ${targetType}, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {")
    // Scalar-only records do not otherwise touch the path context. Keep the
    // generated signature uniform without producing consumer build warnings.
    appendLine(sb, 2, "let _ = context")
    for (field in fields) {
        if (!field.writeField) { continue }
        let codec = fieldCodec(field)
        let directWrite = directScalarWrite(field, "value.${field.name}")
        let writeValue = if (field.staticGenerated) {
            "__yJsonWrite_${field.typeText}(value.${field.name}, writer, context)"
        } else if (directWrite.isEmpty()) { "${codec}.write(value.${field.name}, writer, context)" } else { directWrite }
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
    appendLine(sb, 1, "public func writeDirect(value: ${targetType}, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {")
    if (supportsCompactRaw) {
        appendLine(sb, 2, "if (jsonTryBeginGeneratedCompactRawValue(writer)) { writeCompactRaw(value, writer, context); return }")
    }
    if (isClass) { appendLine(sb, 2, "context.enterObject(value)") } else { appendLine(sb, 2, "context.enterValue()") }
    appendLine(sb, 2, "try {")
    appendLine(sb, 3, "writer.startObject()")
    appendLine(sb, 3, "writeObjectFieldsDirect(value, writer, context)")
    appendLine(sb, 3, "writer.endObject()")
    appendLine(sb, 2, if (isClass) { "} finally { context.leaveObject() }" } else { "} finally { context.leaveValue() }" })
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "private func writeObjectFieldsDirect(value: ${targetType}, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {")
    appendLine(sb, 2, "let _ = context")
    for (field in fields) {
        if (!field.writeField) { continue }
        let codec = fieldCodec(field)
        let directWrite = directScalarWrite(field, "value.${field.name}")
        let writeValue = if (field.staticGenerated) {
            "__yJsonWriteDirect_${field.typeText}(value.${field.name}, writer, context)"
        } else if (directWrite.isEmpty()) {
            "writeJsonDirectWith(${codec}, value.${field.name}, writer, context)"
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
        appendLine(sb, 1, "public func supportsCompactRaw(): Bool { true }")
        appendLine(sb, 1, "public func writeCompactRaw(value: ${targetType}, writer: JsonDirectWriter, context: JsonEncodeContext): Unit {")
        if (isClass) { appendLine(sb, 2, "context.enterObject(value)") } else { appendLine(sb, 2, "context.enterValue()") }
        appendLine(sb, 2, "try {")
        appendLine(sb, 3, "jsonWriteGeneratedCompactObjectBegin(writer)")
        appendLine(sb, 3, "var __first = true")
        for (field in fields) {
            if (!field.writeField) { continue }
            appendLine(sb, 3, compactRawFieldWrite(field, "value.${field.name}", "__first"))
        }
        appendLine(sb, 3, "jsonWriteGeneratedCompactObjectEnd(writer)")
        appendLine(sb, 2, if (isClass) { "} finally { context.leaveObject() }" } else { "} finally { context.leaveValue() }" })
        appendLine(sb, 1, "}")
    }
    appendLine(sb, 1, "public func read(reader: JsonCodecReader, context: JsonDecodeContext): ${targetType} {")
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
        let readValue = if (field.staticGenerated) {
            "__yJsonRead_${field.typeText}(reader, context)"
        } else if (directRead.isEmpty()) { "${codec}.read(reader, context)" } else { directRead }
        let labels = ArrayList<String>()
        labels.add(field.jsonNameExpr)
        labels.add(all: field.aliases)
        appendLine(sb, 5, "case " + joinStrings(labels, " | ") + " =>")
        appendLine(sb, 6, "if (__seen_${field.name} && reader.readConfig().rejectsDuplicateKeys()) { throw JsonException(\"Duplicate JSON field: \" + __name, code: \"duplicate_key\", path: context.currentPath()) }")
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
    appendLine(sb, 6, "if (reader.readConfig().rejectsUnknownFields()) { throw JsonException(\"Unknown JSON field: \" + __name, code: \"unknown_field\", path: context.currentPath()) }")
    appendLine(sb, 6, "reader.skipValueWithDepth(context.remainingDepth())")
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

    // The fast reader is generated from the same field model. It deliberately
    // uses only public JsonFastReader operations so the expansion also works in
    // an unrelated consumer package.
    if (supportsFastRead) {
    appendLine(sb, 1, "public func readFast(reader: JsonFastReader, context: JsonDecodeContext): ${targetType} {")
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
                appendFastFieldAssignment(sb, 4, field, field.jsonNameExpr)
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
        appendFastFieldAssignment(sb, 6, field, label)
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
    appendLine(sb, 2, "} finally { context.leaveValue() }")
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func decodeString(text: String): ${targetType} {")
    appendLine(sb, 2, "let config = JsonReadConfig.defaults")
    appendLine(sb, 2, "let reader = JsonFastReader(text)")
    appendLine(sb, 2, "let result = readFast(reader, JsonDecodeContext(config))")
    appendLine(sb, 2, "reader.expectEnd()")
    appendLine(sb, 2, "result")
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func decodeString(text: String, config!: JsonReadConfig): ${targetType} {")
    appendLine(sb, 2, "let reader = JsonDirectReader(text, config: config)")
    appendLine(sb, 2, "let result = read(reader, JsonDecodeContext(config))")
    appendLine(sb, 2, "reader.expectEnd()")
    appendLine(sb, 2, "result")
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func decodeBytes(bytes: Array<Byte>): ${targetType} {")
    appendLine(sb, 2, "let config = JsonReadConfig.defaults")
    appendLine(sb, 2, "let reader = JsonFastReader(bytes)")
    appendLine(sb, 2, "let result = readFast(reader, JsonDecodeContext(config))")
    appendLine(sb, 2, "reader.expectEnd()")
    appendLine(sb, 2, "result")
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func decodeBytes(bytes: Array<Byte>, config!: JsonReadConfig): ${targetType} {")
    appendLine(sb, 2, "let reader = JsonDirectReader(bytes, config: config)")
    appendLine(sb, 2, "let result = read(reader, JsonDecodeContext(config))")
    appendLine(sb, 2, "reader.expectEnd()")
    appendLine(sb, 2, "result")
    appendLine(sb, 1, "}")
    }
    appendLine(sb, 0, "}")

    let visibility = if (hasModifier(decl, TokenKind.PUBLIC)) { "public " } else { "" }
    let inheritsCodecProvider = if (isClass) {
        match (decl) {
            case classDecl: ClassDecl => !classDecl.superTypes.isEmpty()
            case _ => false
        }
    } else { false }
    if (generics.isEmpty()) {
        appendLine(sb, 0, "private let __yJsonConcrete_${name} = ${codecName}()")
        appendLine(sb, 0, "${visibility}let ${name}Json: JsonCodec<${name}> = __yJsonConcrete_${name}")
        appendLine(sb, 0, "${visibility}func __yJsonWrite_${name}(value: ${name}, writer: JsonCodecWriter, context: JsonEncodeContext): Unit { __yJsonConcrete_${name}.write(value, writer, context) }")
        appendLine(sb, 0, "${visibility}func __yJsonWriteDirect_${name}(value: ${name}, writer: JsonDirectWriter, context: JsonEncodeContext): Unit { __yJsonConcrete_${name}.writeDirect(value, writer, context) }")
        appendLine(sb, 0, "${visibility}func __yJsonRead_${name}(reader: JsonCodecReader, context: JsonDecodeContext): ${name} { __yJsonConcrete_${name}.read(reader, context) }")
        if (supportsFastRead) {
            appendLine(sb, 0, "${visibility}func __yJsonReadFast_${name}(reader: JsonFastReader, context: JsonDecodeContext): ${name} { __yJsonConcrete_${name}.readFast(reader, context) }")
        }
        // Bounded level-one container expansion.  These companions keep the
        // public generic codecs as the compatibility fallback, while allowing
        // a generated object element/value to stay on a concrete call chain.
        appendLine(sb, 0, "private class __YJsonStaticArrayList_${name} <: JsonFastCodec<YJsonArrayList<${name}>> {")
        appendLine(sb, 1, "public func write(value: YJsonArrayList<${name}>, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {")
        appendLine(sb, 2, "context.enterValue(); try { writer.startArray(); if (!value.isEmpty()) { var __index: Int64 = 0; context.pushIndex(0); try { for (__item in value) { if (__index > 0) { context.updateLastIndex(__index) }; __yJsonWrite_${name}(__item, writer, context); __index++ } } finally { context.popPath() } }; writer.endArray() } finally { context.leaveValue() }")
        appendLine(sb, 1, "}")
        appendLine(sb, 1, "public func read(reader: JsonCodecReader, context: JsonDecodeContext): YJsonArrayList<${name}> {")
        appendLine(sb, 2, "context.enterValue(); try { let __result = YJsonArrayList<${name}>(); reader.startArray(); var __index: Int64 = 0; while (reader.hasArrayItem()) { context.pushIndex(__index); try { __result.add(__yJsonRead_${name}(reader, context)) } finally { context.popPath() }; __index++ }; reader.endArray(); return __result } finally { context.leaveValue() }")
        appendLine(sb, 1, "}")
        if (supportsFastRead) {
            appendLine(sb, 1, "public func readFast(reader: JsonFastReader, context: JsonDecodeContext): YJsonArrayList<${name}> {")
            appendLine(sb, 2, "context.enterValue(); try { reader.startRawArray(); if (!reader.hasRawArrayItem(true)) { reader.endRawArray(); return YJsonArrayList<${name}>() }; let __capacity = reader.suggestRawCollectionCapacity(); let __result = if (__capacity > 4) { YJsonArrayList<${name}>(__capacity) } else { YJsonArrayList<${name}>() }; var __first = true; var __index: Int64 = 0; while (reader.hasRawArrayItem(__first)) { reader.beforeRawArrayItem(__first); context.pushIndex(__index); try { __result.add(__yJsonReadFast_${name}(reader, context)) } finally { context.popPath() }; __first = false; __index++ }; reader.endRawArray(); return __result } finally { context.leaveValue() }")
            appendLine(sb, 1, "}")
        }
        appendLine(sb, 0, "}")
        appendLine(sb, 0, "${visibility}let ${name}StaticArrayListJson: JsonCodec<YJsonArrayList<${name}>> = __YJsonStaticArrayList_${name}()")

        appendLine(sb, 0, "private class __YJsonStaticArray_${name} <: JsonFastCodec<Array<${name}>> {")
        appendLine(sb, 1, "public func write(value: Array<${name}>, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {")
        appendLine(sb, 2, "context.enterValue(); try { writer.startArray(); if (!value.isEmpty()) { context.pushIndex(0); try { for (__index in 0..value.size) { if (__index > 0) { context.updateLastIndex(__index) }; __yJsonWrite_${name}(value[__index], writer, context) } } finally { context.popPath() } }; writer.endArray() } finally { context.leaveValue() }")
        appendLine(sb, 1, "}")
        appendLine(sb, 1, "public func read(reader: JsonCodecReader, context: JsonDecodeContext): Array<${name}> {")
        appendLine(sb, 2, "context.enterValue(); try { let __result = YJsonArrayList<${name}>(); reader.startArray(); var __index: Int64 = 0; while (reader.hasArrayItem()) { context.pushIndex(__index); try { __result.add(__yJsonRead_${name}(reader, context)) } finally { context.popPath() }; __index++ }; reader.endArray(); return __result.toArray() } finally { context.leaveValue() }")
        appendLine(sb, 1, "}")
        if (supportsFastRead) {
            appendLine(sb, 1, "public func readFast(reader: JsonFastReader, context: JsonDecodeContext): Array<${name}> {")
            appendLine(sb, 2, "context.enterValue(); try { reader.startRawArray(); if (!reader.hasRawArrayItem(true)) { reader.endRawArray(); return Array<${name}>() }; let __capacity = reader.suggestRawCollectionCapacity(); let __result = if (__capacity > 4) { YJsonArrayList<${name}>(__capacity) } else { YJsonArrayList<${name}>() }; var __first = true; var __index: Int64 = 0; while (reader.hasRawArrayItem(__first)) { reader.beforeRawArrayItem(__first); context.pushIndex(__index); try { __result.add(__yJsonReadFast_${name}(reader, context)) } finally { context.popPath() }; __first = false; __index++ }; reader.endRawArray(); return __result.toArray() } finally { context.leaveValue() }")
            appendLine(sb, 1, "}")
        }
        appendLine(sb, 0, "}")
        appendLine(sb, 0, "${visibility}let ${name}StaticArrayJson: JsonCodec<Array<${name}>> = __YJsonStaticArray_${name}()")

        appendLine(sb, 0, "private class __YJsonStaticOption_${name} <: JsonFastCodec<Option<${name}>> {")
        appendLine(sb, 1, "public func write(value: Option<${name}>, writer: JsonCodecWriter, context: JsonEncodeContext): Unit { match (value) { case Some(__item) => __yJsonWrite_${name}(__item, writer, context); case None => writer.writeNull() } }")
        appendLine(sb, 1, "public func read(reader: JsonCodecReader, context: JsonDecodeContext): Option<${name}> { if (reader.tryReadNull()) { None<${name}> } else { Some(__yJsonRead_${name}(reader, context)) } }")
        if (supportsFastRead) {
            appendLine(sb, 1, "public func readFast(reader: JsonFastReader, context: JsonDecodeContext): Option<${name}> { if (reader.tryReadRawNull()) { None<${name}> } else { Some(__yJsonReadFast_${name}(reader, context)) } }")
        }
        appendLine(sb, 0, "}")
        appendLine(sb, 0, "${visibility}let ${name}StaticOptionJson: JsonCodec<Option<${name}>> = __YJsonStaticOption_${name}()")

        appendLine(sb, 0, "private class __YJsonStaticMap_${name} <: JsonFastCodec<YJsonHashMap<String, ${name}>> {")
        appendLine(sb, 1, "public func write(value: YJsonHashMap<String, ${name}>, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {")
        appendLine(sb, 2, "context.enterValue(); try { writer.startObject(); if (!value.isEmpty()) { var __first = true; try { for ((__name, __item) in value) { writer.writeName(__name); if (__first) { context.pushField(__name); __first = false } else { context.updateLastField(__name) }; __yJsonWrite_${name}(__item, writer, context) } } finally { if (!__first) { context.popPath() } } }; writer.endObject() } finally { context.leaveValue() }")
        appendLine(sb, 1, "}")
        appendLine(sb, 1, "public func read(reader: JsonCodecReader, context: JsonDecodeContext): YJsonHashMap<String, ${name}> {")
        appendLine(sb, 2, "context.enterValue(); try { let __result = YJsonHashMap<String, ${name}>(); reader.startObject(); while (reader.hasObjectField()) { let __name = reader.readName(); context.pushField(__name); try { __result[__name] = __yJsonRead_${name}(reader, context) } finally { context.popPath() } }; reader.endObject(); return __result } finally { context.leaveValue() }")
        appendLine(sb, 1, "}")
        if (supportsFastRead) {
            appendLine(sb, 1, "public func readFast(reader: JsonFastReader, context: JsonDecodeContext): YJsonHashMap<String, ${name}> {")
            appendLine(sb, 2, "context.enterValue(); try { let __result = YJsonHashMap<String, ${name}>(); reader.startRawObject(); var __first = true; while (reader.hasRawObjectField(__first)) { let __name = reader.readRawName(__first); context.pushField(__name); try { __result[__name] = __yJsonReadFast_${name}(reader, context) } finally { context.popPath() }; __first = false }; reader.endRawObject(); return __result } finally { context.leaveValue() }")
            appendLine(sb, 1, "}")
        }
        appendLine(sb, 0, "}")
        appendLine(sb, 0, "${visibility}let ${name}StaticHashMapJson: JsonCodec<YJsonHashMap<String, ${name}>> = __YJsonStaticMap_${name}()")
        appendLine(sb, 0, "func __yJsonCodec_${name}(): JsonCodec<${name}> { ${name}Json }")
        if (!inheritsCodecProvider && !hasModifier(decl, TokenKind.OPEN) && !hasModifier(decl, TokenKind.ABSTRACT)) {
            appendLine(sb, 0, "extend ${name} <: JsonCodecProvider {")
            appendLine(sb, 1, "public static func jsonCodec(): JsonAnyCodec { eraseJsonCodec(${name}Json) }")
            appendLine(sb, 0, "}")
        }
    } else {
        appendLine(sb, 0, "${visibility}func ${name}Json${genericText}(): JsonCodec<${targetType}>${constraints} { ${codecName}${genericText}() }")
        appendLine(sb, 0, "func __yJsonCodec_${name}${genericText}(): JsonCodec<${targetType}>${constraints} { ${name}Json${genericText}() }")
        if (!inheritsCodecProvider && !hasModifier(decl, TokenKind.OPEN) && !hasModifier(decl, TokenKind.ABSTRACT)) {
            appendLine(sb, 0, "extend${genericText} ${targetType} <: JsonCodecProvider${constraints} {")
            appendLine(sb, 1, "public static func jsonCodec(): JsonAnyCodec { eraseJsonCodec(${name}Json${genericText}()) }")
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
    appendLine(sb, 1, "public func write(value: ${targetType}, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {")
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
            appendLine(sb, 5, "try { jsonCodecOf<${typeText}>().write(__item${index}, writer, context) } finally { context.popPath() }")
        }
        appendLine(sb, 5, "writer.endArray()")
    }
    appendLine(sb, 3, "}")
    appendLine(sb, 2, "} finally { context.leaveValue() }")
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func read(reader: JsonCodecReader, context: JsonDecodeContext): ${targetType} {")
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
            appendLine(sb, 5, "let __item${index} = try { jsonCodecOf<${typeText}>().read(reader, context) } finally { context.popPath() }")
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
        appendLine(sb, 0, "extend ${name} <: JsonCodecProvider {")
        appendLine(sb, 1, "public static func jsonCodec(): JsonAnyCodec { eraseJsonCodec(${name}Json) }")
        appendLine(sb, 0, "}")
    } else {
        appendLine(sb, 0, "${visibility}func ${name}Json${genericText}(): JsonCodec<${targetType}>${constraints} { ${codecName}${genericText}() }")
        appendLine(sb, 0, "extend${genericText} ${targetType} <: JsonCodecProvider${constraints} {")
        appendLine(sb, 1, "public static func jsonCodec(): JsonAnyCodec { eraseJsonCodec(${name}Json${genericText}()) }")
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
    appendLine(sb, 0, "private class ${codecName}${genericText} <: JsonCodec<${targetType}>${constraints} {")
    for (field in fields) {
        if (field.codecExpr.isEmpty()) {
            appendLine(sb, 1, "private let ${cachedFieldCodecName(field)}: JsonCodec<${field.typeText}> = ${defaultFieldCodec(field.typeText)}")
        }
    }
    appendLine(sb, 1, "public func write(value: ${targetType}, writer: JsonCodecWriter, context: JsonEncodeContext): Unit {")
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
                appendLine(sb, 6, "try { ${codec}.write(value.${field.name}, writer, context) } finally { context.popPath() }")
                appendLine(sb, 5, "}")
            } else {
                appendLine(sb, 5, "writer.writeName(${field.jsonNameExpr})")
                appendLine(sb, 5, "context.pushField(${field.jsonNameExpr})")
                appendLine(sb, 5, "try { ${codec}.write(value.${field.name}, writer, context) } finally { context.popPath() }")
            }
        }
        appendLine(sb, 5, "match (__yJsonCodec_${subtype.typeText}()) {")
        appendLine(sb, 6, "case __objectCodec: JsonObjectCodec<${subtype.typeText}> => __objectCodec.writeObjectFields(__subtype, writer, context)")
        appendLine(sb, 6, "case _ => throw JsonException(\"Polymorphic subtype codec must be an object codec\", code: \"codec_contract\", path: context.currentPath())")
        appendLine(sb, 5, "}")
    }
    appendLine(sb, 4, "case _ => throw JsonException(\"Unregistered runtime subtype for ${name}\", code: \"unknown_runtime_subtype\", path: context.currentPath())")
    appendLine(sb, 3, "}")
    appendLine(sb, 3, "writer.endObject()")
    appendLine(sb, 2, "} finally { context.leaveObject() }")
    appendLine(sb, 1, "}")
    appendLine(sb, 1, "public func read(reader: JsonCodecReader, context: JsonDecodeContext): ${targetType} {")
    // The subtype codec owns the one JsonDecodeContext container entry for the
    // replayed root object. The polymorphic dispatcher only selects that codec;
    // charging the same object here would make maxDepth=1 reject scalar fields.
    appendLine(sb, 2, "let __replay = reader.readReplayValue(reader.readConfig().maxPolymorphicObjectBytes)")
    appendLine(sb, 2, "try {")
    appendLine(sb, 3, "let __tag = __replay.rootStringField(${discriminator}).getOrThrow({ => JsonException(\"Missing polymorphic discriminator\", code: \"missing_discriminator\", path: context.currentPath()) })")
    appendLine(sb, 3, "match (__tag) {")
    for (subtype in subtypes) {
        appendLine(sb, 4, "case ${subtype.wireNameExpr} =>")
        appendLine(sb, 5, "let __subtypeReader = __replay.openObjectReaderExcluding(${discriminator})")
        appendLine(sb, 5, "let __result: ${targetType} = __yJsonCodec_${subtype.typeText}().read(__subtypeReader, context)")
        appendLine(sb, 5, "__subtypeReader.expectEnd()")
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
        appendLine(sb, 0, "extend ${name} <: JsonCodecProvider {")
        appendLine(sb, 1, "public static func jsonCodec(): JsonAnyCodec { eraseJsonCodec(${name}Json) }")
        appendLine(sb, 0, "}")
    } else {
        appendLine(sb, 0, "${visibility}func ${name}Json${genericText}(): JsonCodec<${targetType}>${constraints} { ${codecName}${genericText}() }")
        appendLine(sb, 0, "extend${genericText} ${targetType} <: JsonCodecProvider${constraints} {")
        appendLine(sb, 1, "public static func jsonCodec(): JsonAnyCodec { eraseJsonCodec(${name}Json${genericText}()) }")
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

/// Opts a field into the generated-to-generated static bridge. The field type
/// must itself use @JsonCodec; custom providers continue to use @JsonUsing or
/// the normal JsonCodecProvider fallback.
public macro JsonStatic(input: Tokens): Tokens {
    quote(
        @JsonStaticMetadata
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
