import SwiftUI
import AppKit

// MARK: - Размеры

enum IslandLayout {
    static let panelWidth: CGFloat = 640
    static let panelHeight: CGFloat = 260
    static let expandedWidth: CGFloat = 460
    static let compactExtra: CGFloat = 120   // ширина «ушек» вокруг чёлки в компактном виде
    static let compactExtraBusy: CGFloat = 300  // со статусом: по 150 с каждой стороны чёлки
    static let roundedCorner: CGFloat = 14
    static let expandedCorner: CGFloat = 22

    @MainActor
    static func size(_ m: AppModel) -> CGSize {
        switch m.mode {
        case .hidden:
            return CGSize(width: m.notchWidth, height: m.notchHeight)
        case .compact:
            // Пока Claude работает — справа широкое «ушко» со статусом.
            let extra: CGFloat = m.shortStatus != nil ? compactExtraBusy : compactExtra
            return CGSize(width: m.notchWidth + extra, height: m.notchHeight)
        case .expanded:
            let content: CGFloat = m.approval != nil ? 150 : 92
            return CGSize(width: expandedWidth, height: m.notchHeight + content)
        }
    }

    /// Центр и диаметр огонька в координатах острова.
    @MainActor
    static func bot(_ m: AppModel, size: CGSize) -> (center: CGPoint, diameter: CGFloat) {
        switch m.mode {
        case .hidden:
            return (CGPoint(x: 46, y: m.notchHeight / 2), 6)
        case .compact:
            let d = min(20, max(0, m.notchHeight - 6))
            return (CGPoint(x: 30, y: m.notchHeight / 2), d)
        case .expanded:
            let top = m.notchHeight
            let d: CGFloat = 50
            return (CGPoint(x: 52, y: top + (size.height - top) / 2), d)
        }
    }
}

// MARK: - Форма острова: прямой верх, скруглённые нижние углы

struct IslandShape: Shape {
    var width: CGFloat
    var height: CGFloat
    var cornerRadius: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { .init(.init(width, height), cornerRadius) }
        set { width = newValue.first.first; height = newValue.first.second; cornerRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let cr = max(0, min(cornerRadius, min(width / 2, height / 2)))
        var p = Path()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: width, y: 0))
        p.addLine(to: CGPoint(x: width, y: height - cr))
        p.addArc(center: CGPoint(x: width - cr, y: height - cr), radius: cr,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: cr, y: height))
        p.addArc(center: CGPoint(x: cr, y: height - cr), radius: cr,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - Корневой вид панели

struct IslandRootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let size = IslandLayout.size(model)
        ZStack(alignment: .top) {
            Color.clear
            ZStack(alignment: .topLeading) {
                IslandShape(width: size.width, height: size.height,
                            cornerRadius: model.mode == .expanded ? IslandLayout.expandedCorner : IslandLayout.roundedCorner)
                    .fill(Color.black)

                if model.mode == .expanded {
                    ExpandedContent(model: model)
                        .frame(width: size.width, height: size.height - model.notchHeight)
                        .offset(y: model.notchHeight)
                        .transition(.opacity)
                }

                if model.mode == .compact {
                    let wing = (size.width - model.notchWidth) / 2
                    HStack(spacing: 6) {
                        CompactIndicator(state: model.botState)
                        if let st = model.shortStatus, wing > 100 {
                            Text(st)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .frame(width: max(0, wing - 18), alignment: .leading)
                    .position(x: size.width - wing / 2, y: model.notchHeight / 2)
                    .transition(.opacity)
                }

                WispPlacement(model: model, size: size)
                    .mask(alignment: .topLeading) {
                        Rectangle().frame(width: size.width,
                                          height: model.mode == .expanded ? IslandLayout.panelHeight : size.height)
                    }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .frame(width: IslandLayout.panelWidth, height: IslandLayout.panelHeight, alignment: .top)
        .coordinateSpace(name: "panel")
        .onPreferenceChange(ButtonFramesKey.self) { frames in
            MainActor.assumeIsolated { AppModel.shared.buttonFrames = frames }
        }
        .ignoresSafeArea()
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: model.approval?.signature)
    }
}

// MARK: - Огонёк на острове

struct WispPlacement: View {
    @ObservedObject var model: AppModel
    let size: CGSize

    var body: some View {
        let (c, d) = IslandLayout.bot(model, size: size)
        let canvas = d / 0.6
        let overhang: CGFloat = 40
        ZStack {
            WispCanvas(model: model, center: c, particleOverhang: overhang)
                .frame(width: canvas, height: canvas + overhang)
                .position(x: c.x, y: c.y - overhang / 2)
                .opacity(model.mode == .hidden ? 0 : 1)
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: c)
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: d)
        .allowsHitTesting(false)
    }

    private func glow(_ s: WispState) -> Color {
        switch s {
        case .working:   return Color(hex: "#3B9EFF")
        case .thinking:  return Color(hex: "#A78BFA")
        case .searching: return Color(hex: "#6366F1")
        case .approval:  return Color(hex: "#F5A524")
        case .error:     return Color(hex: "#F4505E")
        case .finished:  return Color(hex: "#34D399")
        default:         return .white
        }
    }
}

/// Canvas, который каждый кадр рисует огонька.
struct WispCanvas: View {
    @ObservedObject var model: AppModel
    let center: CGPoint
    let particleOverhang: CGFloat
    @StateObject private var engine = WispEngine()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: model.mode == .hidden)) { timeline in
            let frame = timeline.date
            Canvas { context, size in
                _ = frame
                let look = lookXY()
                engine.lookX = look.x
                engine.lookY = look.y
                engine.particleOverhang = particleOverhang
                engine.variant = model.variant
                engine.update(dt: engine.frameDelta())
                engine.draw(context: context, size: size)
            }
        }
        .onChange(of: model.botState) { _, s in engine.setState(s) }
        .onChange(of: model.greeting) { _, g in if g { engine.greet() } }
        .onReceive(NotificationCenter.default.publisher(for: .wispPoke)) { _ in engine.slap() }
        .onAppear {
            engine.variant = model.variant
            engine.setState(model.botState, force: true)
        }
    }

    /// Куда смотрит огонёк — на курсор.
    private func lookXY() -> (x: CGFloat, y: CGFloat) {
        let screen = IslandWindowController.islandScreen().frame
        let islandW = IslandLayout.size(model).width
        let botX = screen.midX - islandW / 2 + center.x
        let mouse = NSEvent.mouseLocation
        let mouseYDown = screen.maxY - mouse.y
        return (tanh((mouse.x - botX) / 260), tanh((mouseYDown - center.y) / 200))
    }
}

extension Notification.Name {
    static let wispPoke = Notification.Name("notchling.poke")
}

// MARK: - Индикатор справа в компактном виде

struct CompactIndicator: View {
    let state: WispState

    var body: some View {
        switch state {
        case .approval:
            Text("!").font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundColor(Color(hex: "#F5A524"))
        case .finished:
            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                .foregroundColor(Color(hex: "#34D399"))
        case .working, .thinking, .searching:
            WorkingDots(color: state == .thinking ? Color(hex: "#A78BFA") : Color(hex: "#3B9EFF"))
        default:
            EmptyView()
        }
    }
}

struct WorkingDots: View {
    let color: Color
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(color)
                        .frame(width: 4, height: 4)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.9)))
                }
            }
        }
    }
}

// MARK: - Развёрнутый вид

struct ExpandedContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Color.clear.frame(width: 100)   // место под огонька
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(model.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    HeaderButton(symbol: "arrow.up.forward.app", help: tr("Открыть Claude", "Open Claude"), id: "open") {
                        ClaudeWatcher.openClaude()
                    }
                    if model.approval != nil {
                        HeaderButton(symbol: "chevron.up", help: tr("Свернуть", "Collapse"), id: "collapse") { model.dismissApproval() }
                    }
                }
                if let d = model.detail, !d.isEmpty {
                    Text(d)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(.white.opacity(0.62))
                        .lineLimit(model.approval != nil ? 3 : 2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let a = model.approval, !a.options.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(a.options) { o in
                            ApprovalButton(option: o) { model.choose(o) }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.trailing, 18)
            .padding(.vertical, 10)
        }
    }
}

/// Координаты кнопок на панели: id → прямоугольник.
struct ButtonFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Сообщить координаты кнопки в пространстве панели.
    func reportFrame(_ id: String) -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: ButtonFramesKey.self, value: [id: g.frame(in: .named("panel"))])
        })
    }
}

struct HeaderButton: View {
    let symbol: String
    let help: String
    var id: String = ""
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(hover ? 0.95 : 0.5))
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(hover ? 0.14 : 0.06)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .reportFrame(id)
    }
}

struct ApprovalButton: View {
    let option: ApprovalOption
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(fg)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(bg.opacity(hover ? 1 : 0.85)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .reportFrame("opt\(option.id)")
    }

    private var label: String {
        switch option.kind {
        case .allowOnce:   return tr("Разрешить", "Allow")
        case .allowSession: return tr("На эту сессию", "This session")
        case .allowAlways: return tr("Всегда", "Always")
        case .deny:        return tr("Отклонить", "Decline")
        case .other:       return option.label
        }
    }
    private var bg: Color {
        switch option.kind {
        case .allowOnce:   return Color(hex: "#34D399")
        case .allowSession: return Color(hex: "#34D399")
        case .allowAlways: return Color.white.opacity(0.16)
        case .deny:        return Color(hex: "#F4505E").opacity(0.9)
        case .other:       return Color.white.opacity(0.16)
        }
    }
    private var fg: Color { (option.kind == .allowOnce || option.kind == .allowSession) ? .black : .white }
}
