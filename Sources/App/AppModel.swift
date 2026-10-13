import SwiftUI
import AppKit

/// Что сейчас делает Claude в чате (по данным наблюдателя).
enum ChatActivity: Equatable {
    case idle
    /// Claude пишет ответ / думает. `label` — текст статуса из интерфейса, если есть.
    case responding(label: String?)
    /// Claude вызывает инструмент: `title` — что делает, `detail` — файл/запрос/аргумент.
    case tool(title: String, detail: String?)
}

/// Вариант ответа на запрос разрешения (кнопка в окне Claude).
struct ApprovalOption: Identifiable, Equatable {
    enum Kind { case allowOnce, allowSession, allowAlways, deny, other }
    let id: Int
    let label: String
    let kind: Kind
}

/// Запрос разрешения, найденный в окне Claude.
struct ApprovalRequest: Equatable {
    /// Подпись запроса — по ней понимаем, что это всё ещё тот же запрос.
    let signature: String
    let title: String
    let detail: String?
    let options: [ApprovalOption]
}

enum IslandMode { case hidden, compact, expanded }

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    // Состояние Claude
    @Published private(set) var activity: ChatActivity = .idle
    @Published private(set) var approval: ApprovalRequest?
    @Published private(set) var justFinished = false
    /// Карточка «Готово» развёрнута несколько секунд после окончания ответа.
    @Published private(set) var showFinishCard = false
    /// Начало последнего ответа Claude (показывается в карточке «Готово»).
    var lastResponse: String?
    @Published var accessibilityGranted = false
    @Published var claudeRunning = false

    // Остров
    @Published var mode: IslandMode = .hidden
    @Published var hovering = false
    /// Пользователь свернул карточку разрешения — не разворачивать её снова, пока запрос тот же.
    @Published var approvalDismissedSignature: String?
    @Published var greeting = false
    /// Где на панели сейчас кнопки (для нажатия с первого клика).
    var buttonFrames: [String: CGRect] = [:]

    // Геометрия
    @Published var notchWidth: CGFloat = 184
    @Published var notchHeight: CGFloat = 32
    @Published var hasNotch = true

    @Published var variant: WispVariant = WispVariant.stored {
        didSet { WispVariant.stored = variant }
    }

    /// Прятать огонька, когда ничего не происходит (по умолчанию — нет, сидит у чёлки всегда).
    var hideWhenIdle: Bool {
        get { UserDefaults.standard.bool(forKey: "hideWhenIdle") }
        set { UserDefaults.standard.set(newValue, forKey: "hideWhenIdle"); recomputeMode() }
    }

    private var finishTimer: Timer?

    /// Состояние огонька — вычисляется из того, что происходит.
    var botState: WispState {
        if approval != nil { return .approval }
        switch activity {
        case .responding: return .thinking
        case .tool(let title, _):
            return (title.hasPrefix("Ищет") || title.hasPrefix("Поискал") || title.hasPrefix("Search")) ? .searching : .working
        case .idle:
            return justFinished ? .finished : .idle
        }
    }

    var isActive: Bool {
        approval != nil || activity != .idle || justFinished || greeting
    }

    // MARK: - Входящие события от наблюдателя

    func update(activity newActivity: ChatActivity, approval newApproval: ApprovalRequest?) {
        let wasBusy = activity != .idle || approval != nil
        if newApproval != approval {
            if let a = newApproval, a.signature != approval?.signature {
                SoundEngine.shared.play("approval")
                approvalDismissedSignature = nil
            }
            approval = newApproval
        }
        if newActivity != activity {
            let wasIdle = activity == .idle
            activity = newActivity
            if wasIdle && newActivity != .idle {
                justFinished = false
                showFinishCard = false
                finishTimer?.invalidate()
                SoundEngine.shared.play("work")
            }
        }
        let busy = activity != .idle || approval != nil
        if wasBusy && !busy {
            // Ответ готов: огонёк радуется несколько секунд и прячется.
            justFinished = true
            showFinishCard = true
            SoundEngine.shared.play("finish")
            finishTimer?.invalidate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
                guard let self, self.justFinished else { return }
                self.showFinishCard = false
                self.recomputeMode()
            }
            finishTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.justFinished = false
                    self?.recomputeMode()
                }
            }
        }
        recomputeMode()
    }

    func recomputeMode() {
        let newMode: IslandMode
        if let a = approval, a.signature != approvalDismissedSignature {
            newMode = .expanded
        } else if hovering || showFinishCard {
            newMode = .expanded
        } else if isActive || !hideWhenIdle {
            newMode = .compact
        } else {
            newMode = .hidden
        }
        if newMode != mode {
            if newMode == .expanded { SoundEngine.shared.play("open") }
            else if mode == .expanded { SoundEngine.shared.play("close") }
            let anim: Animation = newMode.rawOrder > mode.rawOrder
                ? Animation.spring(response: 0.42, dampingFraction: 0.88)
                : Animation.timingCurve(0.45, 0, 0.2, 1, duration: 0.34)
            withAnimation(anim) {
                mode = newMode
            }
        }
    }

    func dismissApproval() {
        approvalDismissedSignature = approval?.signature
        hovering = false
        recomputeMode()
    }

    func choose(_ option: ApprovalOption) {
        guard let a = approval else { return }
        if ClaudeWatcher.shared.press(option: option, of: a) {
            SoundEngine.shared.play(option.kind == .deny ? "close" : "approve")
        } else {
            SoundEngine.shared.play("error")
            ClaudeWatcher.openClaude()
        }
    }

    func greet() {
        greeting = true
        recomputeMode()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [weak self] in
            self?.greeting = false
            self?.recomputeMode()
        }
    }

    // MARK: - Тексты

    /// Короткий статус для правого «ушка» в компактном виде.
    var shortStatus: String? {
        if approval != nil { return tr("Нужно разрешение", "Needs approval") }
        switch activity {
        case .responding(let label): return label ?? tr("Пишет…", "Writing…")
        case .tool(let title, _): return title
        case .idle: return justFinished ? tr("Готово", "Done") : nil
        }
    }

    var title: String {
        if let a = approval { return a.title }
        switch activity {
        case .responding(let label): return label ?? tr("Claude пишет ответ…", "Claude is writing…")
        case .tool(let title, _): return title
        case .idle:
            if !accessibilityGranted { return tr("Нужен доступ «Универсальный доступ»", "Accessibility access needed") }
            if !claudeRunning { return tr("Claude не запущен", "Claude isn’t running") }
            return justFinished ? tr("Готово!", "Done!") : tr("Всё спокойно", "All quiet")
        }
    }

    var detail: String? {
        if let a = approval { return a.detail }
        switch activity {
        case .tool(_, let d): return d
        case .idle where justFinished: return lastResponse
        case .idle where !accessibilityGranted:
            return tr("Настройки → Конфиденциальность и безопасность → Универсальный доступ → Notchling", "System Settings → Privacy & Security → Accessibility → Notchling")
        default: return nil
        }
    }
}

extension IslandMode {
    var rawOrder: Int {
        switch self { case .hidden: 0; case .compact: 1; case .expanded: 2 }
    }
}
