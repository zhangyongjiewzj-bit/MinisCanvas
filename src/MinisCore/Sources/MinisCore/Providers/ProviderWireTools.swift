import Foundation

public extension AgentToolDefinition {
    /// Project/session dispatch rejects every undeclared input key. Preserve
    /// that contract on all native provider wires without modifying the frozen
    /// shared definition type or granting meaning to UI-only metadata.
    var providerOpenAIFunctionDict: [String: Any] {
        var result = openAIFunctionDict
        guard var function = result["function"] as? [String: Any],
              let schema = function["parameters"] as? [String: Any] else { return result }
        function["parameters"] = providerWireInputSchema(schema)
        result["function"] = function
        return result
    }
    var providerAnthropicToolDict: [String: Any] {
        var result = anthropicToolDict
        if let schema = result["input_schema"] as? [String: Any] {
            result["input_schema"] = providerWireInputSchema(schema)
        }
        return result
    }
    private func providerWireInputSchema(_ schema: [String: Any]) -> [String: Any] {
        guard ProjectSessionToolContract.toolNames.contains(name) else { return schema }
        var closed = schema
        closed["additionalProperties"] = false
        return closed
    }

    /// Responses API function-tool shape. Responses does not nest the
    /// function schema under a second `function` object as Chat Completions do.
    var responsesToolDict: [String: Any] {
        var properties: [String: Any] = [:]
        for (name, parameter) in parameters {
            properties[name] = parameter.wireSchema
        }
        return [
            "type": "function",
            "name": name,
            "description": description,
            "parameters": providerWireInputSchema([
                "type": "object",
                "properties": properties,
                "required": required,
            ]),
        ]
    }
}
