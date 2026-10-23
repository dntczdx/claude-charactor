import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let body: Data

    func json<T: Decodable>(_ type: T.Type) -> T? {
        try? JSONDecoder().decode(T.self, from: body)
    }
}

struct HTTPResponse {
    var status: Int
    var body: Data

    init(status: Int = 200, json: Any) {
        self.status = status
        self.body = (try? JSONSerialization.data(withJSONObject: json, options: [])) ?? Data("{}".utf8)
    }
}

/// 只监听 127.0.0.1 的极简 HTTP/1.1 服务器（每个请求一个连接，处理完即关）。
/// MCP 服务器通过它把事件送进来，并长轮询等用户在气泡里的回答。
final class EventServer {
    typealias Handler = (HTTPRequest, @escaping (HTTPResponse) -> Void) -> Void

    private let port: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "claudegirl.http")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: NWEndpoint.Host("127.0.0.1"), port: nwPort)
        let l = try NWListener(using: params)
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: NSLog("[ClaudeGirl] 事件服务器就绪 127.0.0.1:%d", Int(self.port))
            case .failed(let e): NSLog("[ClaudeGirl] 事件服务器失败: %@", String(describing: e))
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: queue)
        listener = l
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for (_, c) in connections { c.cancel() }
        connections.removeAll()
    }

    // MARK: 连接处理（都在 queue 上）

    private func accept(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        connections[key] = conn
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections[key] = nil
            default:
                break
            }
        }
        conn.start(queue: queue)
        read(conn, buffer: Data())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = Self.parse(buf) {
                self.dispatch(req, on: conn)
            } else if isComplete || error != nil || buf.count > 4_000_000 {
                self.close(conn)
            } else {
                self.read(conn, buffer: buf)
            }
        }
    }

    private func dispatch(_ req: HTTPRequest, on conn: NWConnection) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.handler(req) { resp in
                self.queue.async { self.send(resp, on: conn) }
            }
        }
    }

    private func send(_ resp: HTTPResponse, on conn: NWConnection) {
        let reason: String
        switch resp.status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 404: reason = "Not Found"
        default: reason = "Internal Server Error"
        }
        var head = "HTTP/1.1 \(resp.status) \(reason)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(resp.body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(resp.body)
        conn.send(content: out, completion: .contentProcessed { [weak self] _ in
            self?.close(conn)
        })
    }

    private func close(_ conn: NWConnection) {
        conn.cancel()
        connections[ObjectIdentifier(conn)] = nil
    }

    // MARK: 解析

    /// 返回 nil 表示还没收全
    private static func parse(_ buf: Data) -> HTTPRequest? {
        guard let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buf[buf.startIndex..<headEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if name == "content-length" { contentLength = Int(value) ?? 0 }
        }
        let bodyStart = headEnd.upperBound
        guard buf.count - (bodyStart - buf.startIndex) >= contentLength else { return nil }
        let body = buf[bodyStart..<(bodyStart + contentLength)]

        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[target.startIndex..<q])
            let qs = target[target.index(after: q)...]
            for pair in qs.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let k = String(kv[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[0])
                let v = kv.count > 1 ? (String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1])) : ""
                query[k] = v
            }
        }
        return HTTPRequest(method: method, path: path, query: query, body: Data(body))
    }
}
