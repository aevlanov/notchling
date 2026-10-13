import Foundation

/// Читает локальные логи MCP-серверов приложения Claude (~/Library/Logs/Claude/mcp*.log),
/// чтобы знать точное имя инструмента и его аргументы (например, путь читаемого файла).
/// Только чтение файлов на диске, ничего больше.
final class MCPLogTail {
    struct Call: Equatable {
        let server: String
        let tool: String
        let arguments: [String: String]
        let startedAt: Date
    }

    private let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Claude", isDirectory: true)
    private var offsets: [String: UInt64] = [:]
    private var primed = false
    /// Вызовы, на которые сервер ещё не ответил: ключ — "сервер#id".
    private(set) var inFlight: [String: Call] = [:]
    /// Последний вызов (держим несколько секунд, даже если он быстро завершился).
    private(set) var lastCall: Call?

    /// Самый свежий незавершённый вызов, либо только что завершившийся (до 3 с).
    var current: Call? {
        if let c = inFlight.values.max(by: { $0.startedAt < $1.startedAt }) {
            // Зависшие записи старше 2 минут не считаем.
            if Date().timeIntervalSince(c.startedAt) < 120 { return c }
        }
        if let l = lastCall, Date().timeIntervalSince(l.startedAt) < 3 { return l }
        return nil
    }

    func poll() {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in files where name.hasPrefix("mcp") && name.hasSuffix(".log") {
            let path = dir.appendingPathComponent(name).path
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.uint64Value else { continue }
            let old = offsets[path]
            if !primed || old == nil {
                // При первом взгляде начинаем с конца файла: старая история не нужна.
                offsets[path] = size
                continue
            }
            var start = old!
            if size < start { start = 0 }   // лог обрезали/ротировали
            guard size > start, let fh = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? fh.close() }
            try? fh.seek(toOffset: start)
            let data = fh.readData(ofLength: Int(min(size - start, 2_000_000)))
            offsets[path] = start + UInt64(data.count)
            if let text = String(data: data, encoding: .utf8) {
                for line in text.split(separator: "\n") { parse(String(line), file: name) }
            }
        }
        primed = true
        inFlight = inFlight.filter { Date().timeIntervalSince($0.value.startedAt) < 120 }
    }

    // Строки вида:
    // 2026-…Z [filesystem] [info] Message from client: {"method":"tools/call","params":{…},"id":5,…}
    // 2026-…Z [filesystem] [info] Message from server: {"jsonrpc":"2.0","id":5,"result":{…}}
    private func parse(_ line: String, file: String) {
        guard let jsonStart = line.firstIndex(of: "{") else { return }
        let fromClient = line.contains("Message from client")
        let fromServer = line.contains("Message from server")
        guard fromClient || fromServer else { return }
        let server = serverName(line) ?? file
        guard let data = String(line[jsonStart...]).data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let idKey = "\(server)#\(obj["id"].map { "\($0)" } ?? "?")"
        if fromClient, obj["method"] as? String == "tools/call",
           let params = obj["params"] as? [String: Any],
           let tool = params["name"] as? String {
            var args: [String: String] = [:]
            if let a = params["arguments"] as? [String: Any] {
                for (k, v) in a {
                    if let s = v as? String { args[k] = s }
                    else if let arr = v as? [Any] { args[k] = arr.compactMap { $0 as? String }.joined(separator: ", ") }
                    else if let n = v as? NSNumber { args[k] = n.stringValue }
                }
            }
            let call = Call(server: server, tool: tool, arguments: args, startedAt: Date())
            inFlight[idKey] = call
            lastCall = call
        } else if fromServer, obj["result"] != nil || obj["error"] != nil {
            inFlight.removeValue(forKey: idKey)
        }
    }

    private func serverName(_ line: String) -> String? {
        // первая скобка [..] после времени — имя сервера
        guard let open = line.firstIndex(of: "["),
              let close = line[open...].firstIndex(of: "]") else { return nil }
        let name = String(line[line.index(after: open)..<close])
        return name.isEmpty ? nil : name
    }

    // MARK: - Человеческое описание

    static func describe(_ c: Call) -> (title: String, detail: String?) {
        let t = c.tool.lowercased()
        let title: String
        if t.contains("read") || t.contains("get_file") || t.contains("view") || t.contains("open") {
            title = tr("Читает файл", "Reading file")
        } else if t.contains("write") || t.contains("edit") || t.contains("create") || t.contains("update") || t.contains("move") {
            title = tr("Редактирует", "Editing")
        } else if t.contains("list") || t.contains("director") || t.contains("tree") {
            title = tr("Смотрит папку", "Listing folder")
        } else if t.contains("search") || t.contains("find") || t.contains("grep") || t.contains("query") {
            title = tr("Ищет", "Searching")
        } else if t.contains("run") || t.contains("exec") || t.contains("shell") || t.contains("command") {
            title = tr("Выполняет команду", "Running command")
        } else {
            title = tr("Инструмент: \(c.tool)", "Tool: \(c.tool)")
        }
        let keys = ["path", "file_path", "paths", "filename", "source", "destination",
                    "query", "pattern", "url", "command", "name", "title"]
        var detail: String? = nil
        for k in keys { if let v = c.arguments[k], !v.isEmpty { detail = v; break } }
        if detail == nil { detail = c.arguments.values.first }
        if let d = detail {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            detail = d.replacingOccurrences(of: home, with: "~")
        }
        let prefix = c.server.isEmpty ? "" : "\(c.server) · "
        return (title, detail.map { prefix + $0 } ?? (c.server.isEmpty ? nil : c.server))
    }
}
