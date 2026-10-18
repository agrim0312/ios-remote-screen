import Foundation

/// A parsed HTTP/1.1 request head. Bodies are not supported; the relay only serves GET.
public struct HTTPRequest: Equatable {
    public var method: String
    public var path: String
    public var query: [String: String]
    /// Header names are lowercased.
    public var headers: [String: String]

    public var isWebSocketUpgrade: Bool {
        headers["upgrade"]?.lowercased() == "websocket"
            && (headers["connection"]?.lowercased().contains("upgrade") ?? false)
            && headers["sec-websocket-key"] != nil
    }

    static let headerTerminator: [UInt8] = Array("\r\n\r\n".utf8)

    /// Returns the byte length of the request head (including the blank line), or nil if incomplete.
    public static func headLength(in buffer: [UInt8]) -> Int? {
        guard buffer.count >= 4 else { return nil }
        for i in 0...(buffer.count - 4) where buffer[i] == 13 && buffer[i + 1] == 10 && buffer[i + 2] == 13 && buffer[i + 3] == 10 {
            return i + 4
        }
        return nil
    }

    public static func parse(_ head: [UInt8]) -> HTTPRequest? {
        guard let text = String(bytes: head, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return nil }
        let target = String(requestLine[1])
        guard let components = URLComponents(string: "http://localhost" + (target.hasPrefix("/") ? target : "/" + target)) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return HTTPRequest(method: String(requestLine[0]), path: components.path, query: query, headers: headers)
    }
}

public enum HTTPResponse {
    public static func make(status: Int, reason: String, contentType: String, body: Data, extraHeaders: [String: String] = [:]) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        for (k, v) in extraHeaders.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }

    public static func text(_ status: Int, _ reason: String, _ message: String) -> Data {
        make(status: status, reason: reason, contentType: "text/plain; charset=utf-8", body: Data(message.utf8))
    }
}
