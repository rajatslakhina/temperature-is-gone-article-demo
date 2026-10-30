import Foundation

/// Finds and removes the sampling parameters that Claude API version
/// 2026-10-21 rejects with a 400, even at their default values.
/// Works on a single Messages request body and on a Message Batch body
/// (`{"requests": [{"custom_id": ..., "params": {...}}]}`).
public enum LegacyParameterAudit {
    public static let removedParameters = ["temperature", "top_p", "top_k"]

    public struct Finding: Hashable, Sendable, CustomStringConvertible {
        public let path: String
        public let parameter: String
        public let value: String

        public var description: String { "\(path).\(parameter) = \(value)" }
    }

    public enum AuditError: Error, Equatable {
        case notAJSONObject
    }

    public static func audit(_ body: Data) throws -> [Finding] {
        let root = try object(body)
        var findings: [Finding] = []
        findings += scan(root, path: "$")
        if let requests = root["requests"] as? [Any] {
            for (index, entry) in requests.enumerated() {
                if let params = (entry as? [String: Any])?["params"] as? [String: Any] {
                    findings += scan(params, path: "$.requests[\(index)].params")
                }
            }
        }
        return findings
    }

    /// Returns the body with the removed parameters stripped, keys sorted.
    public static func migrate(_ body: Data) throws -> Data {
        var root = try object(body)
        removedParameters.forEach { root.removeValue(forKey: $0) }
        if let requests = root["requests"] as? [Any] {
            root["requests"] = requests.map { entry -> Any in
                guard var request = entry as? [String: Any], var params = request["params"] as? [String: Any] else { return entry }
                removedParameters.forEach { params.removeValue(forKey: $0) }
                request["params"] = params
                return request
            }
        }
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private static func object(_ body: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw AuditError.notAJSONObject
        }
        return root
    }

    private static func scan(_ fields: [String: Any], path: String) -> [Finding] {
        removedParameters.compactMap { name in
            fields[name].map { Finding(path: path, parameter: name, value: "\($0)") }
        }
    }

    /// The request a lot of iOS backends still send.
    public static let legacyExample = """
    {"model":"claude-sonnet-4-6","max_tokens":256,"temperature":0,"top_k":1,"system":"You help triage App Store reviews. Be consistent.","messages":[{"role":"user","content":"Cancelled my trial but the app still says Pro. Is that a bug?"}]}
    """
}
