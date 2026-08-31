package yjson

class JsonParser {
    private let text: String
    private let config: JsonReadOptions

    init(text: String, config!: JsonReadOptions = JsonReadOptions.defaults) {
        this.text = text
        this.config = config
    }

    func parse(): JsonNode {
        parseJsonValueFromText(text, config: config)
    }
}
