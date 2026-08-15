package yjson

class JsonParser {
    private let text: String
    private let config: JsonReadConfig

    init(text: String, config!: JsonReadConfig = JsonReadConfig.defaults) {
        this.text = text
        this.config = config
    }

    func parse(): JsonValue {
        parseJsonValueFromText(text, config: config)
    }
}
