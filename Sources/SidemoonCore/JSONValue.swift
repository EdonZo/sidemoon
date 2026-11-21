import Foundation

/// A JSON value that keeps object key order and number literals exactly, so a settings file
/// can be edited without reordering or reformatting what Sidemoon does not own.
public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case let (.bool(x), .bool(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.array(x), .array(y)): return x == y
        case let (.object(x), .object(y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(pairs) = self { return pairs.first { $0.0 == key }?.1 }
        return nil
    }

    public var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    public var arrayValue: [JSONValue]? { if case let .array(a) = self { return a }; return nil }
    public var objectValue: [(String, JSONValue)]? { if case let .object(o) = self { return o }; return nil }

    /// Returns a copy with `key` set (replacing in place, or appended at the end).
    public func setting(_ key: String, to value: JSONValue?) -> JSONValue {
        guard case var .object(pairs) = self else { return self }
        if let i = pairs.firstIndex(where: { $0.0 == key }) {
            if let value { pairs[i].1 = value } else { pairs.remove(at: i) }
        } else if let value {
            pairs.append((key, value))
        }
        return .object(pairs)
    }
}

// MARK: Parsing

public struct JSONParseError: Error, CustomStringConvertible {
    public let offset: Int
    public let reason: String
    public var description: String { "invalid JSON at byte \(offset): \(reason)" }
}

extension JSONValue {
    public static func parse(_ text: String) throws -> JSONValue {
        var p = Parser(bytes: Array(text.utf8))
        p.skipWhitespace()
        let v = try p.value(depth: 0)
        p.skipWhitespace()
        guard p.i == p.bytes.count else { throw p.fail("trailing characters") }
        return v
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        static let maxDepth = 512

        func fail(_ r: String) -> JSONParseError { JSONParseError(offset: i, reason: r) }

        mutating func skipWhitespace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func expect(_ literal: String) throws {
            let l = Array(literal.utf8)
            guard i + l.count <= bytes.count, Array(bytes[i..<i + l.count]) == l else { throw fail("expected \(literal)") }
            i += l.count
        }

        mutating func value(depth: Int) throws -> JSONValue {
            guard depth < Parser.maxDepth else { throw fail("nesting too deep") }
            guard i < bytes.count else { throw fail("unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func object(depth: Int) throws -> JSONValue {
            i += 1
            var pairs: [(String, JSONValue)] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
            while true {
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected key") }
                let k = try string()
                skipWhitespace()
                try expect(":")
                skipWhitespace()
                pairs.append((k, try value(depth: depth + 1)))
                skipWhitespace()
                guard i < bytes.count else { throw fail("unterminated object") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(pairs) }
                throw fail("expected , or }")
            }
        }

        mutating func array(depth: Int) throws -> JSONValue {
            i += 1
            var items: [JSONValue] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try value(depth: depth + 1))
                skipWhitespace()
                guard i < bytes.count else { throw fail("unterminated array") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw fail("expected , or ]")
            }
        }

        mutating func string() throws -> String {
            i += 1
            var out = [UInt8]()
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") { i += 1; return String(decoding: out, as: UTF8.self) }
                if c < 0x20 { throw fail("control character in string") }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { break }
                    let e = bytes[i]
                    switch e {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if (0xD800..<0xDC00).contains(code), i + 2 < bytes.count,
                           bytes[i + 1] == UInt8(ascii: "\\"), bytes[i + 2] == UInt8(ascii: "u") {
                            i += 2
                            let low = try hex4()
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        out.append(contentsOf: Array(String(UnicodeScalar(code).map(Character.init) ?? "\u{FFFD}").utf8))
                    default: throw fail("bad escape")
                    }
                    i += 1
                    continue
                }
                out.append(c)
                i += 1
            }
            throw fail("unterminated string")
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 < bytes.count, let v = UInt32(String(decoding: bytes[i + 1...i + 4], as: UTF8.self), radix: 16)
            else { throw fail("bad unicode escape") }
            i += 4
            return v
        }

        mutating func number() throws -> String {
            let start = i
            while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
            let s = String(decoding: bytes[start..<i], as: UTF8.self)
            guard !s.isEmpty, Double(s) != nil else { throw fail("bad value") }
            return s
        }
    }
}

// MARK: Serializing

extension JSONValue {
    /// Pretty output with two-space indentation, matching how Claude Code writes settings files.
    public func serialized(indent: String = "  ") -> String {
        var out = ""
        write(&out, level: 0, indent: indent)
        return out
    }

    private func write(_ out: inout String, level: Int, indent: String) {
        let pad = String(repeating: indent, count: level + 1)
        let closePad = String(repeating: indent, count: level)
        switch self {
        case .null: out += "null"
        case let .bool(b): out += b ? "true" : "false"
        case let .number(n): out += n
        case let .string(s): out += JSONValue.quote(s)
        case let .array(items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (n, item) in items.enumerated() {
                out += pad
                item.write(&out, level: level + 1, indent: indent)
                out += n < items.count - 1 ? ",\n" : "\n"
            }
            out += closePad + "]"
        case let .object(pairs):
            if pairs.isEmpty { out += "{}"; return }
            out += "{\n"
            for (n, (k, v)) in pairs.enumerated() {
                out += pad + JSONValue.quote(k) + ": "
                v.write(&out, level: level + 1, indent: indent)
                out += n < pairs.count - 1 ? ",\n" : "\n"
            }
            out += closePad + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }
}
