import AppKit
import ApplicationServices

/// Следит за окном приложения Claude через Accessibility API (только чтение дерева интерфейса)
/// и нажимает кнопку разрешения ТОЛЬКО когда пользователь сам нажал её в чёлке.
/// Никакой сети, ничего не сохраняет на диск.
@MainActor
final class ClaudeWatcher {
    static let shared = ClaudeWatcher()
    static let bundleId = "com.anthropic.claudefordesktop"

    private let model = AppModel.shared
    private let mcp = MCPLogTail()
    private var timer: Timer?
    private var axApp: AXUIElement?
    private var pid: pid_t = 0
    private var emptyStreak = 0

    /// Кнопки вариантов текущей карточки разрешения (по id варианта).
    private var optionElements: [Int: AXUIElement] = [:]
    /// Строка чата в боковой панели, который ждёт разрешения (чтобы открыть его).
    private var awaitingRowElement: AXUIElement?

    // MARK: - Запуск

    func start() {
        requestAccessibility()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.attach() }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.attach() }
        }
        attach()
        schedule(interval: 0.7)
    }

    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        model.accessibilityGranted = AXIsProcessTrustedWithOptions(opts)
    }

    private func schedule(interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private var manualSet = false
    /// Последняя увиденная карточка разрешения (держим, пока чат ждёт).
    private var lastCard: ApprovalRequest?
    private var lastCardElements: [Int: AXUIElement] = [:]
    private var lastCardLabels: [Int: String] = [:]
    private var lastCardSeen = Date.distantPast
    private var idleSince: Date?
    private var history: [String] = []
    private var lastLine = ""
    private var lastDiag = Date.distantPast
    /// Папка для диагностики: ~/Library/Logs/Notchling (только локально).
    /// В режиме разработки build.sh записывает сюда папку проекта (ключ diagDir).
    static var logDir: URL {
        if let d = UserDefaults.standard.string(forKey: "diagDir"), !d.isEmpty {
            return URL(fileURLWithPath: d, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Notchling", isDirectory: true)
    }
    /// Вести отладочный журнал (переключается в меню).
    var debugLog: Bool {
        get { UserDefaults.standard.bool(forKey: "debugLog") }
        set { UserDefaults.standard.set(newValue, forKey: "debugLog") }
    }

    private func attach(force: Bool = false) {
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleId).first
        model.claudeRunning = app != nil
        guard let app else { axApp = nil; pid = 0; manualSet = false; return }
        if app.processIdentifier != pid || force || axApp == nil {
            pid = app.processIdentifier
            let el = AXUIElementCreateApplication(pid)
            // Electron открывает дерево веб-контента для Accessibility только с этим флагом.
            let r = AXUIElementSetAttributeValue(el, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            manualSet = (r == .success)
            axApp = el
        }
    }

    /// Сохраняет диагностику в ~/Library/Logs/Notchling/diag.txt (без текста сообщений).
    func writeDiagnostics() -> URL? {
        var out = "trusted=\(AXIsProcessTrusted()) pid=\(pid) claudeRunning=\(model.claudeRunning)\n"
        if axApp == nil { attach() }
        if let axApp {
            var winRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(axApp, "AXWindows" as CFString, &winRef)
            out += "AXWindows err=\(err.rawValue) count=\((winRef as? [AXUIElement])?.count ?? -1)\n"
            var manual: CFTypeRef?
            let me = AXUIElementCopyAttributeValue(axApp, "AXManualAccessibility" as CFString, &manual)
            out += "AXManualAccessibility err=\(me.rawValue) value=\(String(describing: manual))\n"
            Snapshot.multiOK = 0; Snapshot.multiFail = 0
            out += Snapshot.take(app: axApp).summary
        }
        out += "model: activity=\(model.activity) approval=\(model.approval?.title ?? "-") mode=\(model.mode)\n"
        out += "--- история ---\n" + history.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: Self.logDir, withIntermediateDirectories: true)
        let url = Self.logDir.appendingPathComponent("diag.txt")
        do { try out.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }

    static func openClaude() {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: - Опрос

    private func tick() {
        if !model.accessibilityGranted {
            model.accessibilityGranted = AXIsProcessTrusted()
            if !model.accessibilityGranted {
                if debugLog, Date().timeIntervalSince(lastDiag) > 3 {
                    lastDiag = Date(); _ = writeDiagnostics()
                }
                return
            }
            manualSet = false   // доступ только что появился — заново включаем чтение окна
        }
        if axApp == nil || !manualSet { attach(force: !manualSet) }
        guard let axApp else {
            optionElements = [:]
            model.update(activity: .idle, approval: nil)
            return
        }
        mcp.poll()

        let snap = Snapshot.take(app: axApp)
        debugRecord(snap)
        if snap.nodeCount == 0 {
            // Окно Claude не на экране (другой стол, свёрнуто) — macOS временно отдаёт пустое
            // дерево. Это не «закончил», а «не знаю»: оставляем последнее состояние как есть.
            emptyStreak += 1
            return
        }
        emptyStreak = 0
        apply(snap)
    }

    /// Отладка: если включён журнал — раз в 3 с пишем сводку в diag.txt.
    private func debugRecord(_ snap: Snapshot) {
        let line = "nodes=\(snap.nodeCount) stop=\(snap.stopVisible) step=\(snap.liveStep ?? "-") running=\(snap.runningRows.count) awaiting=\(snap.awaitingRows.count) card=\(snap.permissionCard?.title ?? "-") btns=\(snap.permissionCard?.buttons.map { $0.label } ?? []) loose=\(snap.looseButtons.map { $0.label })"
        if line != lastLine {
            lastLine = line
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            history.append("\(f.string(from: Date())) \(line)")
            if history.count > 60 { history.removeFirst(history.count - 60) }
        }
        guard debugLog, Date().timeIntervalSince(lastDiag) > 3 else { return }
        lastDiag = Date()
        _ = writeDiagnostics()
    }

    private func apply(_ s: Snapshot) {
        // 1. Разрешение
        var approval: ApprovalRequest? = nil
        optionElements = [:]
        awaitingRowElement = s.awaitingRows.first?.element
        if s.permissionCard == nil, let last = lastCard, !s.awaitingRows.isEmpty,
           Date().timeIntervalSince(lastCardSeen) < 300 {
            // Карточка перестроилась в дереве Accessibility (заголовка не видно), а чат всё ещё
            // ждёт разрешения — показываем ту же карточку, без перестройки чёлки.
            approval = last
        } else if let card = s.permissionCard {
            var opts: [ApprovalOption] = []
            for (i, b) in card.buttons.enumerated() {
                opts.append(ApprovalOption(id: i, label: b.label, kind: Self.kind(of: b.label)))
                optionElements[i] = b.element
            }
            // Отклонить — последней, «Разрешить» — первой.
            opts.sort { Self.order($0.kind) < Self.order($1.kind) }
            var lines = card.fields.map { "\(Self.ru($0.0)): \($0.1)" }
            if lines.isEmpty, let n = card.note { lines.append(n) }
            approval = ApprovalRequest(signature: card.signature,
                                       title: Self.translateTitle(card.title),
                                       detail: lines.joined(separator: "\n"),
                                       options: opts)
            lastCard = approval
            lastCardElements = optionElements
            lastCardLabels = Dictionary(uniqueKeysWithValues: card.buttons.enumerated().map { ($0.offset, $0.element.label) })
            lastCardSeen = Date()
        } else if let row = s.awaitingRows.first {
            // Разрешения ждёт чат, который сейчас не открыт: даём кнопку «Открыть чат».
            approval = ApprovalRequest(signature: "awaiting:\(row.title)",
                                       title: tr("Claude ждёт твоего разрешения", "Claude is waiting for your approval"),
                                       detail: tr("Чат «\(row.title)»", "Chat “\(row.title)”"),
                                       options: [ApprovalOption(id: -1, label: tr("Открыть чат", "Open chat"), kind: .other)])
        }

        if approval == nil || approval?.signature.hasPrefix("awaiting:") == true {
            if s.permissionCard == nil && s.awaitingRows.isEmpty { lastCard = nil; lastCardElements = [:] }
        }

        // 2. Что делает Claude
        var activity: ChatActivity = .idle
        let busy = s.stopVisible || !s.runningRows.isEmpty || s.liveStep != nil
        if busy {
            if let call = mcp.current {
                let d = MCPLogTail.describe(call)
                activity = .tool(title: d.title, detail: d.detail)
            } else if let step = s.liveStep {
                let t = Self.translateStep(step)
                activity = Self.isThinkingStep(step) ? .responding(label: t) : .tool(title: t, detail: chatDetail(s))
            } else if let st = s.liveStatus {
                activity = .responding(label: Self.translateStep(st))
            } else {
                activity = .responding(label: s.thinking ? tr("Думает…", "Thinking…") : nil)
            }
        }
        if let r = s.lastResponse { model.lastResponse = r }
        // «Закончил» засчитываем, только если Claude бездействует дольше 1.2 с подряд:
        // интерфейс на мгновение убирает кнопку «Stop» между шагами.
        if activity == .idle, approval == nil, model.activity != .idle {
            if idleSince == nil { idleSince = Date() }
            if Date().timeIntervalSince(idleSince!) < 1.2 {
                model.update(activity: model.activity, approval: nil)
                return
            }
        }
        if activity != .idle { idleSince = nil }
        model.update(activity: activity, approval: approval)
    }

    /// Название чата, если он работает в фоне (не тот, что открыт).
    private func chatDetail(_ s: Snapshot) -> String? {
        guard let r = s.runningRows.first, r.title != s.openChatTitle else { return nil }
        return tr("Чат «\(r.title)»", "Chat “\(r.title)”")
    }

    // MARK: - Нажатие кнопки (только по клику пользователя в чёлке)

    func press(option: ApprovalOption, of request: ApprovalRequest) -> Bool {
        if option.id == -1 {
            // Открыть ждущий чат: нажать его строку в боковой панели и вывести Claude вперёд.
            if let row = awaitingRowElement { AXUIElementPerformAction(row, kAXPressAction as CFString) }
            Self.openClaude()
            return true
        }
        guard let axApp else { return false }
        // Перед нажатием убеждаемся, что на экране всё ещё ТОТ ЖЕ запрос.
        let fresh = Snapshot.take(app: axApp)
        var candidates: [AXUIElement] = []
        if let card = fresh.permissionCard {
            guard card.signature == request.signature, option.id < card.buttons.count,
                  card.buttons[option.id].label == option.label else { return false }
            candidates.append(card.buttons[option.id].element)
        } else if request.signature == lastCard?.signature, !fresh.awaitingRows.isEmpty {
            // Карточка перестроилась: тот же запрос всё ещё ждёт. Ищем живую кнопку с той же
            // надписью по всему окну, запасной вариант — запомненная ссылка.
            candidates += fresh.looseButtons.filter { $0.label == option.label }.map(\.element)
            if lastCardLabels[option.id] == option.label, let el = lastCardElements[option.id] { candidates.append(el) }
        }
        var ok = false
        for el in candidates where AXUIElementPerformAction(el, kAXPressAction as CFString) == .success {
            ok = true; break
        }
        // Кнопка «Allow» в Claude игнорирует первое нажатие, пока окно Claude не в фокусе
        // (защита от случайных подтверждений). Если через мгновение ТОТ ЖЕ запрос всё ещё
        // висит — нажимаем ещё раз, один раз.
        if ok, option.kind != .deny {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.retryPress(option: option, request: request)
            }
        }
        if ok { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.tick() } }
        return ok
    }

    private func retryPress(option: ApprovalOption, request: ApprovalRequest) {
        guard let axApp else { return }
        let fresh = Snapshot.take(app: axApp)
        guard !fresh.awaitingRows.isEmpty else { return }   // уже не ждёт — всё сработало
        var el: AXUIElement?
        if let card = fresh.permissionCard {
            guard card.signature == request.signature, option.id < card.buttons.count,
                  card.buttons[option.id].label == option.label else { return }
            el = card.buttons[option.id].element
        } else if request.signature == lastCard?.signature {
            el = fresh.looseButtons.first { $0.label == option.label }?.element
            if el == nil, lastCardLabels[option.id] == option.label { el = lastCardElements[option.id] }
        }
        if let el { AXUIElementPerformAction(el, kAXPressAction as CFString) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.tick() }
    }

    // MARK: - Переводы и классификация

    static func kind(of label: String) -> ApprovalOption.Kind {
        let l = label.lowercased()
        if l.contains("decline") || l.contains("deny") || l.contains("don't") || l.contains("reject") || l.contains("cancel") { return .deny }
        if l.contains("always") { return .allowAlways }
        if l.contains("session") { return .allowSession }
        if l.contains("allow") || l.contains("approve") || l.contains("continue") { return .allowOnce }
        return .other
    }

    static func order(_ k: ApprovalOption.Kind) -> Int {
        switch k { case .allowOnce: 0; case .allowSession: 1; case .allowAlways: 2; case .other: 3; case .deny: 4 }
    }

    static func ru(_ term: String) -> String {
        guard L10n.language == .ru else { return term }
        return switch term.lowercased() {
        case "folder": "Папка"
        case "why", "reason": "Зачем"
        case "app", "application": "Приложение"
        case "file": "Файл"
        case "tool": "Инструмент"
        case "command": "Команда"
        case "url", "site", "website": "Сайт"
        default: term
        }
    }

    static func translateTitle(_ t: String) -> String {
        let l = t.lowercased()
        if L10n.language == .en { return t.isEmpty ? "Approval needed" : t }
        if l.contains("permanently delete") { return "Claude хочет удалять файлы" }
        if l.contains("use a folder") || l.contains("access to a folder") { return "Claude просит доступ к папке" }
        if l.contains("control") && l.contains("app") { return "Claude хочет управлять приложением" }
        if l.isEmpty { return "Нужно разрешение" }
        return t
    }

    /// Перевод строк шагов из интерфейса Claude. Незнакомое оставляем как есть.
    private static let stepRules: [(String, String)] = [
        ("getting set up for this session", "готовится"),
        ("requesting access to a folder on your computer", "просит доступ к папке"),
        ("requested access to a folder on your computer", "запросил доступ к папке"),
        ("reading files on your computer", "читает файлы на компьютере"),
        ("listing files on your computer", "смотрит файлы на компьютере"),
        ("listed files on your computer", "посмотрел файлы на компьютере"),
        ("using computer", "работает с компьютером"),
        ("used computer", "поработал с компьютером"),
        ("using the browser", "работает в браузере"),
        ("used the browser", "поработал в браузере"),
        ("read files on your computer", "прочитал файлы на компьютере"),
        ("selecting the right device tool to use", "выбирает инструмент"),
        ("searched connector directory", "поискал коннекторы"),
        ("running a command", "выполняет команду"),
        ("ran a command", "выполнил команду"),
        ("ran commands", "выполнил команды"),
        ("searching the web", "ищет в интернете"),
        ("searched the web", "поискал в интернете"),
        ("loading tools", "подбирает инструменты"),
        ("loaded tools", "подобрал инструменты"),
        ("updating tasks", "обновляет задачи"),
        ("updated tasks", "обновил задачи"),
        ("created a file", "создал файл"),
        ("edited a file", "отредактировал файл"),
        ("read a file", "прочитал файл"),
        ("thinking", "думает…"),
        ("reading ", "читает "), ("read ", "прочитал "),
        ("searching ", "ищет: "), ("searched ", "поискал: "),
        ("creating ", "создаёт "), ("created ", "создал "),
        ("editing ", "редактирует "), ("edited ", "отредактировал "),
        ("writing ", "пишет "), ("wrote ", "написал "),
        ("fetching ", "открывает "), ("fetched ", "открыл "),
        ("viewing ", "смотрит "), ("viewed ", "посмотрел "),
        ("running ", "выполняет: "),
    ]

    /// Шаг «Claude думает» (Thinking, или одно «весёлое» слово вроде Mulling, Pondering).
    static func isThinkingStep(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: " .")).lowercased()
        return t.hasPrefix("thinking") || (!t.contains(" ") && t.hasSuffix("ing"))
    }

    static func translateStep(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        // Интерфейс Claude на английском: в английском режиме показываем как есть.
        if L10n.language == .en {
            if isThinkingStep(trimmed) && !trimmed.contains(" ") { return trimmed + "…" }
            return trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        }
        // Одно «весёлое» слово вроде Mulling, Sleuthing, Pondering — Claude думает.
        if !trimmed.contains(" "), trimmed.lowercased().hasSuffix("ing") { return "Думает…" }
        let parts = trimmed.components(separatedBy: ", ").map { part -> String in
            let l = part.lowercased()
            for (en, ru) in stepRules where l.hasPrefix(en) {
                return ru + part.dropFirst(en.count)
            }
            return part
        }
        var joined = parts.joined(separator: ", ")
        // Счётчики: «ran 4 commands», «and 5 more steps»
        for (pattern, template) in [("(?i)ran (\\d+) commands", "выполнил команд: $1"),
                                    ("(?i)read (\\d+) files", "прочитал файлов: $1"),
                                    ("(?i)edited (\\d+) files", "изменил файлов: $1"),
                                    ("(?i)and (\\d+) more steps?", "и ещё шагов: $1"),
                                    ("(?i)(\\d+) more steps?", "ещё шагов: $1")] {
            joined = joined.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }
}

// MARK: - Снимок интерфейса

/// Один проход по дереву окна Claude. Одним вызовом AXUIElementCopyMultipleAttributeValues
/// на узел, без чтения текста сообщений (кроме строк статуса шагов).
struct Snapshot {
    struct Row { let title: String; let element: AXUIElement }
    struct Button { let label: String; let element: AXUIElement }
    struct Card {
        var title = ""
        var note: String?
        var fields: [(String, String)] = []
        var buttons: [Button] = []
        var signature: String { ([title] + fields.map { "\($0.0)=\($0.1)" }).joined(separator: "|") }
    }

    var nodeCount = 0
    var stopVisible = false
    var thinking = false
    var liveStep: String?
    /// Строка статуса внутри отвечающего сообщения («Selecting the right tool…»).
    var liveStatus: String?
    /// Первая фраза последнего ответа Claude (из заголовка «Claude responded: …»).
    var lastResponse: String?
    /// Для отладки: структура стримящегося сообщения (только кнопки/статусы, обрезано).
    var streamLines: [String] = []
    var runningRows: [Row] = []
    var awaitingRows: [Row] = []
    var openChatTitle: String?
    var permissionCard: Card?
    /// Кнопки Allow/Decline, найденные где угодно в окне (на случай, если карточка
    /// перестроилась и уже не помечена как «Permission request»).
    var looseButtons: [Button] = []

    private static let attrs = ["AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXValue", "AXChildren"] as CFArray

    private struct Node {
        let el: AXUIElement
        let role: String
        let subrole: String
        let title: String
        let desc: String
        let value: String
        let children: [AXUIElement]
    }

    /// Статистика последнего прохода (для диагностики).
    nonisolated(unsafe) static var multiOK = 0
    nonisolated(unsafe) static var multiFail = 0

    private static func read(_ el: AXUIElement) -> Node? {
        var values: CFArray?
        if AXUIElementCopyMultipleAttributeValues(el, attrs, AXCopyMultipleAttributeOptions(rawValue: 0), &values) == .success,
           let arr = values as? [AnyObject], arr.count == 6 {
            multiOK += 1
            func s(_ i: Int) -> String { (arr[i] as? String) ?? "" }
            let kids = (arr[5] as? [AXUIElement]) ?? []
            return Node(el: el, role: s(0), subrole: s(1), title: s(2), desc: s(3), value: s(4), children: kids)
        }
        // Запасной путь: по одному атрибуту.
        multiFail += 1
        func one(_ name: String) -> AnyObject? {
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
        }
        guard let role = one("AXRole") as? String else { return nil }
        return Node(el: el, role: role,
                    subrole: (one("AXSubrole") as? String) ?? "",
                    title: (one("AXTitle") as? String) ?? "",
                    desc: (one("AXDescription") as? String) ?? "",
                    value: (one("AXValue") as? String) ?? "",
                    children: (one("AXChildren") as? [AXUIElement]) ?? [])
    }

    /// Текстовая сводка для диагностики (без текста сообщений).
    var summary: String {
        var out = "nodes=\(nodeCount) stop=\(stopVisible) thinking=\(thinking) step=\(liveStep ?? "-")\n"
        out += "openChat=\(openChatTitle ?? "-")\n"
        out += "running=\(runningRows.map { $0.title })\nawaiting=\(awaitingRows.map { $0.title })\n"
        if let c = permissionCard {
            out += "card.title=\(c.title)\ncard.fields=\(c.fields.map { "\($0.0): \($0.1)" })\ncard.buttons=\(c.buttons.map { $0.label })\n"
        } else { out += "card=nil\n" }
        out += "status=\(liveStatus ?? "-")\nlastResponse=\((lastResponse ?? "-").prefix(60))\n"
        out += "multiOK=\(Snapshot.multiOK) multiFail=\(Snapshot.multiFail)\n"
        out += "--- стрим ---\n" + streamLines.joined(separator: "\n") + "\n"
        return out
    }

    static func take(app: AXUIElement) -> Snapshot {
        var snap = Snapshot()
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &winRef) == .success,
              let windows = winRef as? [AXUIElement] else { return snap }
        for w in windows {
            if let n = read(w) { snap.walk(n, depth: 0, inStreaming: false) }
        }
        return snap
    }

    private mutating func walk(_ n: Node, depth: Int, inStreaming: Bool) {
        guard depth < 70, nodeCount < 6000 else { return }
        nodeCount += 1

        if n.role == "AXWebArea", !n.title.isEmpty, n.title.hasSuffix(" - Claude") {
            openChatTitle = String(n.title.dropLast(9))
        }

        // Карточка разрешения — разбираем отдельно и дальше не спускаемся.
        if n.subrole == "AXApplicationGroup", n.desc.hasPrefix("Permission request") {
            permissionCard = Self.parseCard(n)
            return
        }

        if n.role == "AXButton" {
            if n.desc == "Stop response" || n.desc == "Stop" { stopVisible = true }
            if Self.isApprovalLabel(n.title) { looseButtons.append(Button(label: n.title, element: n.el)) }
            // Шаг в стриминге: кнопка «<шаг> running»
            if inStreaming, n.title.hasSuffix(" running") {
                liveStep = String(n.title.dropLast(8))
            }
        }
        if n.role == "AXStaticText", n.value == "Claude is thinking" { thinking = true }
        if n.role == "AXHeading", n.title.hasPrefix("Claude responded: ") {
            lastResponse = String(n.title.dropFirst(18))
        }
        if inStreaming, streamLines.count < 60, n.role != "AXGroup" || !n.desc.isEmpty {
            let label = [n.title, n.desc, n.value].first { !$0.isEmpty } ?? ""
            streamLines.append("\(String(repeating: " ", count: min(depth, 40)))\(n.role)\(n.subrole.isEmpty ? "" : "/" + n.subrole) \(label.prefix(70))")
        }
        if inStreaming, n.subrole == "AXApplicationStatus" {
            for c in n.children {
                if let k = Self.read(c), k.role == "AXStaticText", !k.value.isEmpty, k.value != "running" {
                    liveStatus = k.value
                }
            }
        }

        // Строки чатов в боковой панели: [AXButton title=имя] + [AXApplicationStatus desc=Running/Awaiting input]
        var rowTitle: String?
        var rowEl: AXUIElement?
        var streaming = inStreaming || n.desc == "Currently streaming message"
        var kids: [Node] = []
        for c in n.children { if let k = Self.read(c) { kids.append(k) } }
        for k in kids {
            if k.role == "AXButton", !k.title.isEmpty, rowTitle == nil { rowTitle = k.title; rowEl = k.el }
            if k.subrole == "AXApplicationStatus", let t = rowTitle, let e = rowEl {
                if k.desc == "Running" { runningRows.append(Row(title: t, element: e)) }
                else if k.desc == "Awaiting input" { awaitingRows.append(Row(title: t, element: e)) }
            }
        }
        if n.desc == "Currently streaming message" { streaming = true }
        for k in kids { walk(k, depth: depth + 1, inStreaming: streaming) }
    }

    static func isApprovalLabel(_ t: String) -> Bool {
        let l = t.lowercased()
        return ["decline", "deny", "allow", "allow once", "allow for this session", "always allow",
                "don't allow", "approve", "reject"].contains(l) || l.hasPrefix("allow for ")
    }

    private static func parseCard(_ root: Node) -> Card {
        var card = Card()
        var pendingTerm: String?
        var count = 0
        func visit(_ n: Node, inNote: Bool) {
            guard count < 400 else { return }
            count += 1
            if n.role == "AXButton", !n.title.isEmpty {
                if card.title.isEmpty { card.title = n.title }
                else { card.buttons.append(Button(label: n.title, element: n.el)) }
                return
            }
            if n.subrole == "AXTerm" { pendingTerm = n.title }
            let note = inNote || n.subrole == "AXDocumentNote"
            if n.role == "AXStaticText", !n.value.isEmpty {
                if let term = pendingTerm, n.value != term {
                    card.fields.append((term, n.value.replacingOccurrences(of: "\n", with: " ")))
                    pendingTerm = nil
                } else if note, card.note == nil, n.value != "From the tool:" {
                    card.note = n.value.replacingOccurrences(of: "\n", with: " ")
                }
            }
            for c in n.children { if let k = read(c) { visit(k, inNote: note) } }
        }
        for c in root.children { if let k = read(c) { visit(k, inNote: false) } }
        return card
    }
}
