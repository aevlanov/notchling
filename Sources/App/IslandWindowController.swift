import AppKit
import SwiftUI
import Combine

/// Хостинг SwiftUI, который принимает первый клик: иначе, пока Notchling неактивен,
/// первый клик по кнопке только «будит» окно и кнопку приходится нажимать дважды.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Прозрачная панель над чёлкой. Пропускает клики, пока остров не развёрнут.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// Не даём macOS сдвинуть панель ниже строки меню — она должна сидеть в чёлке.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class IslandWindowController {
    static let shared = IslandWindowController()

    private var panel: IslandPanel!
    private let model = AppModel.shared
    private var pointerTimer: Timer?
    private var outsideSince: Date?
    private var cancellables: Set<AnyCancellable> = []
    private var clickMonitor: Any?

    /// Экран с чёлкой (или главный, если чёлки нет).
    static func islandScreen() -> NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    func start() {
        panel = IslandPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        let host = FirstClickHostingView(rootView: IslandRootView(model: model))
        host.frame = NSRect(x: 0, y: 0, width: IslandLayout.panelWidth, height: IslandLayout.panelHeight)
        panel.contentView = host

        layout()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layout() }
        }

        // Клики пропускаются сквозь панель, пока остров не развёрнут.
        model.$mode.sink { [weak self] m in
            self?.panel.ignoresMouseEvents = (m != .expanded)
        }.store(in: &cancellables)

        // Клик по огоньку в развёрнутом виде — тык (после пяти тыков у него кружится голова).
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] e in
            guard let self, e.window === self.panel, self.model.mode == .expanded else { return e }
            let p = e.locationInWindow
            // Кнопки нажимаем сами по их координатам — с первого клика, даже когда
            // Notchling неактивен. Событие гасим, чтобы кнопка не сработала дважды.
            let hit = CGPoint(x: p.x, y: IslandLayout.panelHeight - p.y)
            for (key, rect) in self.model.buttonFrames where rect.contains(hit) {
                switch key {
                case "open": ClaudeWatcher.openClaude()
                case "collapse": self.model.dismissApproval()
                default:
                    if key.hasPrefix("opt"), let id = Int(key.dropFirst(3)),
                       let o = self.model.approval?.options.first(where: { $0.id == id }) {
                        self.model.choose(o)
                    }
                }
                return nil
            }
            let size = IslandLayout.size(self.model)
            let (c, d) = IslandLayout.bot(self.model, size: size)
            let originX = (IslandLayout.panelWidth - size.width) / 2
            let yDown = IslandLayout.panelHeight - p.y
            if hypot(p.x - (originX + c.x), yDown - c.y) < d * 0.7 {
                NotificationCenter.default.post(name: .wispPoke, object: nil)
            }
            return e
        }

        // Наведение курсора на чёлку: 10 раз в секунду, только координаты мыши.
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkPointer() }
        }
    }

    private func layout() {
        let screen = Self.islandScreen()
        let aux = (screen.auxiliaryTopLeftArea?.width, screen.auxiliaryTopRightArea?.width)
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        let geo = NotchGeometry(screenWidth: screen.frame.width,
                                safeAreaTop: screen.safeAreaInsets.top,
                                leftArea: aux.0, rightArea: aux.1,
                                menuBarHeight: menuBar)
        model.hasNotch = geo.hasNotch
        model.notchWidth = geo.width
        model.notchHeight = geo.height
        let f = screen.frame
        panel.setFrame(NSRect(x: f.midX - IslandLayout.panelWidth / 2,
                              y: f.maxY - IslandLayout.panelHeight,
                              width: IslandLayout.panelWidth, height: IslandLayout.panelHeight),
                       display: true)
    }

    /// Прямоугольник острова на экране (координаты Cocoa).
    private func islandRect(margin: CGFloat) -> NSRect {
        let f = Self.islandScreen().frame
        let s = IslandLayout.size(model)
        let w = max(s.width, model.notchWidth)
        return NSRect(x: f.midX - w / 2 - margin, y: f.maxY - s.height - margin,
                      width: w + margin * 2, height: s.height + margin)
    }

    private func checkPointer() {
        let mouse = NSEvent.mouseLocation
        if model.mode == .expanded {
            if islandRect(margin: 12).contains(mouse) {
                outsideSince = nil
            } else if model.hovering {
                if outsideSince == nil { outsideSince = Date() }
                if Date().timeIntervalSince(outsideSince!) > 0.35 {
                    outsideSince = nil
                    model.hovering = false
                    model.recomputeMode()
                }
            }
        } else if islandRect(margin: 0).contains(mouse) {
            model.hovering = true
            // Свёрнутая карточка разрешения разворачивается снова по наведению.
            model.approvalDismissedSignature = nil
            model.recomputeMode()
        }
    }
}


/// Размер чёлки экрана. Если чёлки нет — небольшая полоска вверху экрана.
struct NotchGeometry {
    let hasNotch: Bool
    let width: CGFloat
    let height: CGFloat

    init(screenWidth: CGFloat, safeAreaTop: CGFloat, leftArea: CGFloat?, rightArea: CGFloat?, menuBarHeight: CGFloat) {
        hasNotch = safeAreaTop > 0
        if hasNotch {
            if let l = leftArea, let r = rightArea, screenWidth - l - r > 0 {
                width = screenWidth - l - r
            } else {
                width = 184
            }
            height = safeAreaTop
        } else {
            width = 80
            height = min(24, menuBarHeight)
        }
    }
}
