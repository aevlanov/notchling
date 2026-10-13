// ax-dump.swift — снимает структуру (Accessibility-дерево) окон приложения Claude.
// Ничего не отправляет в сеть, ничего не нажимает. Пишет текстовые файлы рядом с собой.
//
// Запуск:  swift ax-dump.swift          — снимки каждые 2 с в течение 90 с
//          swift ax-dump.swift once     — один снимок
//          swift ax-dump.swift 300      — снимки 300 секунд
//
// Терминалу нужен доступ «Универсальный доступ» (System Settings → Privacy & Security → Accessibility).

import AppKit
import ApplicationServices
import CryptoKit

let bundleId = "com.anthropic.claudefordesktop"
let maxNodes = 25_000
let maxDepth = 80
let maxText = 100

let runStamp: String = { let f = DateFormatter(); f.dateFormat = "HHmmss"; return f.string(from: Date()) }()
let outDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    .appendingPathComponent("ax-dumps-\(runStamp)", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) else {
    print("Нет доступа Accessibility. Разреши Терминалу в System Settings → Privacy & Security → Accessibility и запусти снова.")
    exit(1)
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else {
    print("Приложение Claude не запущено."); exit(1)
}
let axApp = AXUIElementCreateApplication(app.processIdentifier)
// Electron отдаёт дерево веб-контента только после этого флага.
AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
Thread.sleep(forTimeInterval: 1.0)

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}
func str(_ el: AXUIElement, _ name: String) -> String? {
    guard let v = attr(el, name) else { return nil }
    var s: String
    if let x = v as? String { s = x }
    else if let x = v as? NSNumber { s = x.stringValue }
    else if let arr = v as? [String] { s = arr.joined(separator: " ") }
    else { return nil }
    s = s.replacingOccurrences(of: "\n", with: "⏎")
    if s.isEmpty { return nil }
    return s.count > maxText ? String(s.prefix(maxText)) + "…" : s
}
func actions(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(el, &names) == .success, let a = names as? [String] else { return [] }
    return a.filter { $0 != "AXShowMenu" && $0 != "AXScrollToVisible" }
}

func dump() -> String {
    var out = ""
    var count = 0
    func walk(_ el: AXUIElement, _ depth: Int) {
        guard count < maxNodes, depth < maxDepth else { return }
        count += 1
        var parts: [String] = [str(el, "AXRole") ?? "?"]
        if let s = str(el, "AXSubrole") { parts.append("sub=\(s)") }
        if let s = str(el, "AXTitle") { parts.append("title=\"\(s)\"") }
        if let s = str(el, "AXDescription") { parts.append("desc=\"\(s)\"") }
        if let s = str(el, "AXValue") { parts.append("value=\"\(s)\"") }
        if let s = str(el, "AXHelp") { parts.append("help=\"\(s)\"") }
        if let s = str(el, "AXIdentifier") { parts.append("id=\(s)") }
        if let s = str(el, "AXDOMIdentifier") { parts.append("domid=\(s)") }
        if let s = str(el, "AXDOMClassList") { parts.append("class=\"\(s)\"") }
        if let s = str(el, "AXEnabled"), s == "0" { parts.append("disabled") }
        let acts = actions(el)
        if !acts.isEmpty { parts.append("act=\(acts.joined(separator: ","))") }
        out += String(repeating: "  ", count: depth) + parts.joined(separator: " ") + "\n"
        if let kids = attr(el, "AXChildren") as? [AXUIElement] {
            for k in kids { walk(k, depth + 1) }
        }
    }
    let windows = (attr(axApp, "AXWindows") as? [AXUIElement]) ?? []
    for (i, w) in windows.enumerated() {
        out += "=== WINDOW \(i) ===\n"
        walk(w, 0)
    }
    out += "=== nodes: \(count) ===\n"
    return out
}

let arg = CommandLine.arguments.dropFirst().first ?? ""
let once = arg == "once"
let seconds = Int(arg) ?? 90
let shots = once ? 1 : seconds / 2
var lastHash = ""
var saved = 0
print("Снимаю окно Claude\(once ? "" : " \(seconds) секунд — за это время отправь сообщение и дождись ответа/окна разрешения")…")
for i in 0..<shots {
    let text = dump()
    let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    if hash != lastHash {
        lastHash = hash
        saved += 1
        let name = String(format: "dump-%02d.txt", i)
        try? text.write(to: outDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        print("  снимок \(name)")
    }
    if !once { Thread.sleep(forTimeInterval: 2.0) }
}
print("Готово: \(saved) снимков в \(outDir.path)")
