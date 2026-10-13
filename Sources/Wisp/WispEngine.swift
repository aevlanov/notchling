import SwiftUI
import QuartzCore

// Огонёк — персонаж Notchling. Рисуется кодом в Canvas, без картинок.

// MARK: - Состояния

enum WispState: String, CaseIterable {
    case idle, thinking, working, searching, approval, finished, error
}

// MARK: - Варианты огоньков

enum WispVariant: String, CaseIterable, Identifiable {
    case sky, ember, mint, moon, plum

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sky:   tr("Голубой", "Sky")
        case .ember: tr("Янтарный", "Ember")
        case .mint:  tr("Мятный", "Mint")
        case .moon:  tr("Лунный", "Moon")
        case .plum:  tr("Сливовый", "Plum")
        }
    }

    /// Цвета: кончик пламени, середина, ядро (внутренний свет), свечение.
    var palette: (tip: Color, mid: Color, core: Color, glow: Color) {
        switch self {
        case .sky:   (Color(hex: "#2F6BFF"), Color(hex: "#4FA3FF"), Color(hex: "#D9F0FF"), Color(hex: "#5AB0FF"))
        case .ember: (Color(hex: "#FF4D2E"), Color(hex: "#FF9A3D"), Color(hex: "#FFF0C2"), Color(hex: "#FF8A3D"))
        case .mint:  (Color(hex: "#0FA98F"), Color(hex: "#2ED3B7"), Color(hex: "#E2FFF8"), Color(hex: "#3BE3C4"))
        case .moon:  (Color(hex: "#9AA6D6"), Color(hex: "#D7DCF2"), Color(hex: "#FFFFFF"), Color(hex: "#C9D2FF"))
        case .plum:  (Color(hex: "#7B3FE4"), Color(hex: "#B07BFF"), Color(hex: "#F3E8FF"), Color(hex: "#A66BFF"))
        }
    }

    /// Форма кончика пламени.
    enum Tip { case single, double, tall, round, curl }
    var tip: Tip {
        switch self {
        case .sky: .single
        case .ember: .double
        case .mint: .tall
        case .moon: .round
        case .plum: .curl
        }
    }

    static var stored: WispVariant {
        get { WispVariant(rawValue: UserDefaults.standard.string(forKey: "wispVariant") ?? "") ?? .sky }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "wispVariant") }
    }
}

// MARK: - Пружина

struct WSpring {
    var value: CGFloat
    var velocity: CGFloat = 0
    var target: CGFloat
    var stiffness: CGFloat
    var damping: CGFloat

    init(_ v: CGFloat, stiffness: CGFloat = 180, damping: CGFloat = 14) {
        value = v; target = v; self.stiffness = stiffness; self.damping = damping
    }

    mutating func step(_ dt: CGFloat) {
        let a = -stiffness * (value - target) - damping * velocity
        velocity += a * dt
        value += velocity * dt
    }
    mutating func kick(_ v: CGFloat) { velocity += v }
}

// MARK: - Частицы

private struct Particle {
    enum Kind { case ember, spark }
    var kind: Kind
    var x: CGFloat, y: CGFloat      // в долях R от центра тела
    var vx: CGFloat, vy: CGFloat
    var age: CGFloat = 0
    var life: CGFloat
    var size: CGFloat
    var rot: CGFloat = 0
}

// MARK: - Движок

@MainActor
final class WispEngine: ObservableObject {
    var variant: WispVariant = .sky
    var lookX: CGFloat = 0
    var lookY: CGFloat = 0
    var particleOverhang: CGFloat = 0

    private(set) var state: WispState = .idle
    private var t: CGFloat = 0
    private var lastFrame: CFTimeInterval = 0

    /// Реальное время с прошлого кадра — скорость анимации не зависит от частоты экрана.
    func frameDelta() -> Double {
        let now = CACurrentMediaTime()
        defer { lastFrame = now }
        guard lastFrame > 0 else { return 1.0 / 60.0 }
        return min(0.05, max(0.001, now - lastFrame))
    }

    // Анимация тела
    private var sx = WSpring(1, stiffness: 260, damping: 12)
    private var sy = WSpring(1, stiffness: 260, damping: 12)
    private var oy = WSpring(0, stiffness: 140, damping: 11)     // прыжок (≈ в долях R)
    private var ox = WSpring(0, stiffness: 400, damping: 18)     // тряска
    private var scale = WSpring(1, stiffness: 120, damping: 9)   // появление
    private var flare = WSpring(1, stiffness: 90, damping: 10)   // высота пламени
    private var glow = WSpring(0.35, stiffness: 60, damping: 12)
    private var badge = WSpring(0, stiffness: 220, damping: 14)
    private var spin: CGFloat = 0
    private var spinStart: CGFloat = -10
    private var spinDuration: CGFloat = 0.8

    // Глаза
    private var eyeLX = WSpring(0, stiffness: 120, damping: 14)
    private var eyeLY = WSpring(0, stiffness: 120, damping: 14)
    private var blinkUntil: CGFloat = 0
    private var nextBlink: CGFloat = 2
    private var winkUntil: CGFloat = 0
    private var ouchUntil: CGFloat = 0
    private var dizzyUntil: CGFloat = 0
    private var slapTimes: [CGFloat] = []

    private var nextHop: CGFloat = 0
    private var nextEmber: CGFloat = 0
    private var particles: [Particle] = []

    // MARK: Управление

    func setState(_ s: WispState, force: Bool = false) {
        guard s != state || force else { return }
        state = s
        badge.target = (s == .approval || s == .error) ? 1 : 0
        switch s {
        case .finished:
            oy.kick(-9)
            sx.kick(-3); sy.kick(4)
            startSpin(0.85)
            burst(12)
            glow.target = 0.9
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                if self?.state == .finished { self?.glow.target = 0.5 }
            }
        case .approval:
            oy.kick(-6)
            nextHop = t + 1.3
            glow.target = 0.85
        case .error:
            ox.kick(14)
            glow.target = 0.6
        case .working, .searching:
            glow.target = 0.6
        case .thinking:
            glow.target = 0.5
        case .idle:
            glow.target = 0.35
        }
        flare.target = (s == .approval) ? 1.18 : (s == .working || s == .searching ? 1.08 : 1)
        blink()
    }

    func greet() {
        scale.value = 0.05; scale.velocity = 0; scale.target = 1
        oy.kick(-5)
        winkUntil = t + 0.9
        burst(6)
        SoundEngine.shared.play("greet")
    }

    func slap() {
        sx.kick(5); sy.kick(-6)
        ox.kick(CGFloat.random(in: -8...8))
        ouchUntil = t + 0.45
        slapTimes.append(t)
        slapTimes = slapTimes.filter { t - $0 < 2.5 }
        if slapTimes.count >= 5 {
            slapTimes.removeAll()
            dizzyUntil = t + 1.8
            startSpin(1.3)
            SoundEngine.shared.play("dizzy")
        } else {
            SoundEngine.shared.play("slap")
        }
    }

    func blink() { blinkUntil = t + 0.13 }

    private func startSpin(_ duration: CGFloat) {
        spinStart = t; spinDuration = duration
    }

    private func burst(_ n: Int) {
        for i in 0..<n {
            let a = CGFloat(i) / CGFloat(n) * .pi * 2 + CGFloat.random(in: -0.3...0.3)
            let sp = CGFloat.random(in: 1.6...2.6)
            particles.append(Particle(kind: .spark, x: cos(a) * 0.4, y: -0.2 + sin(a) * 0.4,
                                      vx: cos(a) * sp, vy: sin(a) * sp - 0.8,
                                      life: CGFloat.random(in: 0.6...0.9),
                                      size: CGFloat.random(in: 0.13...0.2), rot: a))
        }
    }

    // MARK: Шаг анимации

    func update(dt rawDt: Double) {
        let dt = CGFloat(min(rawDt, 0.05))
        t += dt

        // Моргание
        if t > nextBlink {
            blink()
            nextBlink = t + CGFloat.random(in: 2.2...5.5)
        }

        // Подпрыгивания, пока ждём разрешения
        if state == .approval, t > nextHop {
            oy.kick(-6); sy.kick(3)
            nextHop = t + 1.3
        }

        // Тряска при ошибке
        if state == .error, Int(t * 10) % 25 == 0 { ox.kick(CGFloat.random(in: -2...2)) }

        // Искорки поднимаются, пока работаем
        let emberRate: CGFloat
        switch state {
        case .working, .searching: emberRate = 0.18
        case .thinking: emberRate = 0.45
        case .approval: emberRate = 0.3
        default: emberRate = 1.6
        }
        if t > nextEmber {
            nextEmber = t + emberRate * CGFloat.random(in: 0.7...1.3)
            particles.append(Particle(kind: .ember,
                                      x: CGFloat.random(in: -0.35...0.35), y: -1.0,
                                      vx: CGFloat.random(in: -0.15...0.15), vy: CGFloat.random(in: -1.1 ... -0.6),
                                      life: CGFloat.random(in: 0.8...1.4),
                                      size: CGFloat.random(in: 0.05...0.09)))
        }
        for i in particles.indices {
            particles[i].age += dt
            particles[i].x += particles[i].vx * dt
            particles[i].y += particles[i].vy * dt
            if particles[i].kind == .spark {
                particles[i].vx *= 0.94; particles[i].vy = particles[i].vy * 0.94 + 0.9 * dt
                particles[i].rot += dt * 4
            } else {
                particles[i].vx += sin(t * 3 + CGFloat(i)) * 0.4 * dt
            }
        }
        particles.removeAll { $0.age >= $0.life }

        // Куда смотрят глаза
        var lx = lookX, ly = lookY
        switch state {
        case .thinking: lx = 0.6 + sin(t * 0.8) * 0.15; ly = -0.7
        case .searching: lx = sin(t * 3.2); ly = 0.1
        default: break
        }
        eyeLX.target = max(-1, min(1, lx))
        eyeLY.target = max(-1, min(1, ly))

        // Дыхание
        let breath = 1 + sin(t * 2.1) * 0.025
        sy.target = breath
        sx.target = 2 - breath

        sx.step(dt); sy.step(dt); oy.step(dt); ox.step(dt); scale.step(dt)
        flare.step(dt); glow.step(dt); badge.step(dt); eyeLX.step(dt); eyeLY.step(dt)

        // Вращение (кувырок)
        let p = (t - spinStart) / spinDuration
        spin = (p >= 0 && p < 1) ? easeOut(p) * .pi * 2 : 0
    }

    private func easeOut(_ x: CGFloat) -> CGFloat { 1 - pow(1 - x, 3) }

    // MARK: Рисование

    func draw(context: GraphicsContext, size: CGSize) {
        let W = size.width
        let H = size.height
        let R = W * 0.27
        let pal = variant.palette
        let cx = W / 2 + ox.value * R * 0.25
        let cy = H / 2 + particleOverhang / 2 + R * 0.35 + oy.value * R * 0.9

        // Свечение
        var g = context
        g.addFilter(.blur(radius: R * 0.55))
        g.opacity = Double(max(0, min(1, glow.value)))
        g.fill(Path(ellipseIn: CGRect(x: cx - R * 1.25, y: cy - R * 1.5, width: R * 2.5, height: R * 2.6)),
               with: .color(pal.glow))

        // Частицы-искорки за телом
        drawParticles(context, cx: cx, cy: cy, R: R, behind: true)

        var ctx = context
        ctx.translateBy(x: cx, y: cy)
        if spin != 0 { ctx.rotate(by: .radians(Double(spin))) }
        ctx.scaleBy(x: sx.value * scale.value, y: sy.value * scale.value)

        let flicker = flickerAmount()
        let body = flamePath(R: R, height: flare.value, flicker: flicker)

        // Внешнее пламя: градиент от кончика к основанию
        ctx.fill(body, with: .linearGradient(
            Gradient(stops: [.init(color: pal.tip, location: 0),
                             .init(color: pal.mid, location: 0.55),
                             .init(color: pal.mid.opacity(0.95), location: 1)]),
            startPoint: CGPoint(x: 0, y: -R * 1.9), endPoint: CGPoint(x: 0, y: R)))

        // Внутреннее ядро
        var core = ctx
        core.translateBy(x: 0, y: R * 0.22)
        core.scaleBy(x: 0.68, y: 0.66)
        core.opacity = 0.92
        core.fill(flamePath(R: R, height: flare.value * 0.85, flicker: flicker * 1.4, phase: 1.7),
                  with: .radialGradient(Gradient(colors: [pal.core, pal.core.opacity(0.75)]),
                                        center: CGPoint(x: 0, y: R * 0.2), startRadius: 0, endRadius: R * 1.2))

        drawFace(ctx, R: R)
        drawBadge(context, cx: cx, cy: cy, R: R)
        drawParticles(context, cx: cx, cy: cy, R: R, behind: false)
    }

    private func flickerAmount() -> CGFloat {
        switch state {
        case .working, .searching: 1.6
        case .approval: 1.8
        case .thinking: 1.1
        case .finished: 1.3
        case .error: 0.7
        case .idle: 0.8
        }
    }

    /// Контур пламени: круглое основание и кончик(и), которые колышутся.
    private func flamePath(R: CGFloat, height: CGFloat, flicker: CGFloat, phase: CGFloat = 0) -> Path {
        let speed: CGFloat = state == .idle ? 3.2 : 5.5
        let s1 = sin(t * speed + phase) * 0.12 * flicker * R + sin(t * speed * 2.3 + phase) * 0.05 * flicker * R
        let s2 = sin(t * speed * 1.3 + phase + 2) * 0.1 * flicker * R
        var p = Path()
        p.move(to: CGPoint(x: 0, y: R))
        p.addCurve(to: CGPoint(x: -R, y: 0), control1: CGPoint(x: -0.56 * R, y: R), control2: CGPoint(x: -R, y: 0.56 * R))

        switch variant.tip {
        case .single:
            // кончик + боковой язычок справа
            let tip = CGPoint(x: s1, y: -1.75 * R * height)
            p.addCurve(to: tip, control1: CGPoint(x: -R, y: -0.62 * R),
                       control2: CGPoint(x: s1 * 0.6 - 0.32 * R, y: -1.05 * R * height))
            p.addQuadCurve(to: CGPoint(x: 0.3 * R, y: -0.95 * R * height),
                           control: CGPoint(x: 0.24 * R + s1 * 0.5, y: -1.25 * R * height))
            p.addQuadCurve(to: CGPoint(x: 0.66 * R + s2, y: -1.3 * R * height),
                           control: CGPoint(x: 0.5 * R, y: -1.02 * R * height))
            p.addCurve(to: CGPoint(x: R, y: 0), control1: CGPoint(x: 0.88 * R, y: -0.9 * R * height),
                       control2: CGPoint(x: R, y: -0.5 * R))
        case .tall:
            // боковой язычок слева + высокий кончик
            p.addCurve(to: CGPoint(x: -0.62 * R + s2, y: -1.35 * R * height), control1: CGPoint(x: -R, y: -0.5 * R),
                       control2: CGPoint(x: -0.88 * R, y: -0.95 * R * height))
            p.addQuadCurve(to: CGPoint(x: -0.3 * R, y: -1.0 * R * height),
                           control: CGPoint(x: -0.48 * R, y: -1.05 * R * height))
            p.addQuadCurve(to: CGPoint(x: s1, y: -2.05 * R * height),
                           control: CGPoint(x: -0.3 * R + s1 * 0.5, y: -1.5 * R * height))
            p.addCurve(to: CGPoint(x: R, y: 0), control1: CGPoint(x: s1 * 0.6 + 0.32 * R, y: -1.05 * R * height),
                       control2: CGPoint(x: R, y: -0.62 * R))
        case .round:
            let h: CGFloat = 1.45
            let tip = CGPoint(x: s1, y: -h * R * height)
            p.addCurve(to: tip, control1: CGPoint(x: -R, y: -0.62 * R),
                       control2: CGPoint(x: s1 * 0.6 - 0.32 * R, y: -1.05 * R * height))
            p.addCurve(to: CGPoint(x: R, y: 0), control1: CGPoint(x: s1 * 0.6 + 0.32 * R, y: -1.05 * R * height),
                       control2: CGPoint(x: R, y: -0.62 * R))
        case .double:
            let tipL = CGPoint(x: -0.38 * R + s2, y: -1.5 * R * height)
            let valley = CGPoint(x: 0.02 * R + s1 * 0.3, y: -0.95 * R * height)
            let tipR = CGPoint(x: 0.42 * R + s1, y: -1.85 * R * height)
            p.addCurve(to: tipL, control1: CGPoint(x: -R, y: -0.55 * R), control2: CGPoint(x: -0.68 * R, y: -1.1 * R * height))
            p.addQuadCurve(to: valley, control: CGPoint(x: -0.2 * R, y: -1.15 * R * height))
            p.addQuadCurve(to: tipR, control: CGPoint(x: 0.12 * R, y: -1.45 * R * height))
            p.addCurve(to: CGPoint(x: R, y: 0), control1: CGPoint(x: 0.75 * R, y: -1.2 * R * height),
                       control2: CGPoint(x: R, y: -0.6 * R))
        case .curl:
            let tip = CGPoint(x: 0.5 * R + s1, y: -1.85 * R * height)
            let hook = CGPoint(x: 0.12 * R + s1, y: -1.62 * R * height)
            p.addCurve(to: tip, control1: CGPoint(x: -R, y: -0.7 * R),
                       control2: CGPoint(x: -0.2 * R + s1 * 0.5, y: -2.05 * R * height))
            p.addQuadCurve(to: hook, control: CGPoint(x: 0.42 * R + s1, y: -1.6 * R * height))
            p.addCurve(to: CGPoint(x: R, y: 0), control1: CGPoint(x: 0.5 * R, y: -1.25 * R * height),
                       control2: CGPoint(x: R, y: -0.62 * R))
        }
        p.addCurve(to: CGPoint(x: 0, y: R), control1: CGPoint(x: R, y: 0.56 * R), control2: CGPoint(x: 0.56 * R, y: R))
        p.closeSubpath()
        return p
    }

    // MARK: Лицо

    private enum Eye { case open, wide, happy, closed, ouch, spiral, flat }

    private func eyeShape() -> (left: Eye, right: Eye) {
        if t < dizzyUntil { return (.spiral, .spiral) }
        if t < ouchUntil { return (.ouch, .ouch) }
        if t < winkUntil { return (.open, .happy) }
        switch state {
        case .finished: return (.happy, .happy)
        case .approval: return t < blinkUntil ? (.closed, .closed) : (.wide, .wide)
        case .error: return (.flat, .flat)
        default: return t < blinkUntil ? (.closed, .closed) : (.open, .open)
        }
    }

    private func drawFace(_ ctx: GraphicsContext, R: CGFloat) {
        let ink = Color(hex: "#1D1631")
        let shapes = eyeShape()
        let ex = 0.34 * R
        let ey = 0.18 * R
        let lx = eyeLX.value * R * 0.14
        let ly = eyeLY.value * R * 0.1
        for (i, side) in [CGFloat(-1), 1].enumerated() {
            let c = CGPoint(x: side * ex + lx, y: ey + ly)
            drawEye(ctx, shape: i == 0 ? shapes.left : shapes.right, at: c, R: R, ink: ink, side: side)
        }
        // Щёчки
        let cheek = Color(hex: "#FF7FA8").opacity(state == .finished || t < winkUntil ? 0.55 : 0.32)
        for side in [CGFloat(-1), 1] {
            ctx.fill(Path(ellipseIn: CGRect(x: side * 0.6 * R - 0.12 * R + lx * 0.6, y: 0.42 * R + ly * 0.6,
                                            width: 0.24 * R, height: 0.12 * R)), with: .color(cheek))
        }
        // Ротик
        let mouthY = 0.46 * R + ly
        var m = Path()
        switch state {
        case .finished:
            m.move(to: CGPoint(x: -0.14 * R + lx, y: mouthY - 0.02 * R))
            m.addQuadCurve(to: CGPoint(x: 0.14 * R + lx, y: mouthY - 0.02 * R),
                           control: CGPoint(x: lx, y: mouthY + 0.2 * R))
            ctx.stroke(m, with: .color(ink), style: StrokeStyle(lineWidth: max(1, 0.07 * R), lineCap: .round))
        case .approval:
            ctx.fill(Path(ellipseIn: CGRect(x: lx - 0.06 * R, y: mouthY - 0.04 * R, width: 0.12 * R, height: 0.14 * R)),
                     with: .color(ink))
        case .error:
            m.move(to: CGPoint(x: -0.1 * R + lx, y: mouthY + 0.06 * R))
            m.addQuadCurve(to: CGPoint(x: 0.1 * R + lx, y: mouthY + 0.06 * R), control: CGPoint(x: lx, y: mouthY - 0.04 * R))
            ctx.stroke(m, with: .color(ink), style: StrokeStyle(lineWidth: max(1, 0.06 * R), lineCap: .round))
        default:
            m.move(to: CGPoint(x: -0.07 * R + lx, y: mouthY))
            m.addQuadCurve(to: CGPoint(x: 0.07 * R + lx, y: mouthY), control: CGPoint(x: lx, y: mouthY + 0.08 * R))
            ctx.stroke(m, with: .color(ink), style: StrokeStyle(lineWidth: max(0.8, 0.05 * R), lineCap: .round))
        }
    }

    private func drawEye(_ ctx: GraphicsContext, shape: Eye, at c: CGPoint, R: CGFloat, ink: Color, side: CGFloat) {
        let lw = max(1, 0.07 * R)
        let stroke = StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round)
        switch shape {
        case .open, .wide:
            let w = (shape == .wide ? 0.24 : 0.19) * R
            let h = (shape == .wide ? 0.32 : 0.27) * R
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)), with: .color(ink))
            // блик
            let hw = w * 0.42
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - w * 0.32, y: c.y - h * 0.36, width: hw, height: hw)),
                     with: .color(.white.opacity(0.95)))
        case .closed:
            var p = Path()
            p.move(to: CGPoint(x: c.x - 0.1 * R, y: c.y))
            p.addLine(to: CGPoint(x: c.x + 0.1 * R, y: c.y))
            ctx.stroke(p, with: .color(ink), style: stroke)
        case .happy:
            var p = Path()
            p.move(to: CGPoint(x: c.x - 0.11 * R, y: c.y + 0.04 * R))
            p.addQuadCurve(to: CGPoint(x: c.x + 0.11 * R, y: c.y + 0.04 * R), control: CGPoint(x: c.x, y: c.y - 0.14 * R))
            ctx.stroke(p, with: .color(ink), style: stroke)
        case .ouch:
            var p = Path()
            p.move(to: CGPoint(x: c.x - 0.09 * R * side, y: c.y - 0.09 * R))
            p.addLine(to: CGPoint(x: c.x + 0.07 * R * side, y: c.y))
            p.addLine(to: CGPoint(x: c.x - 0.09 * R * side, y: c.y + 0.09 * R))
            ctx.stroke(p, with: .color(ink), style: stroke)
        case .flat:
            var p = Path()
            p.move(to: CGPoint(x: c.x - 0.1 * R, y: c.y - 0.03 * R * side))
            p.addLine(to: CGPoint(x: c.x + 0.1 * R, y: c.y + 0.03 * R * side))
            ctx.stroke(p, with: .color(ink), style: stroke)
        case .spiral:
            var p = Path()
            let turns: CGFloat = 2.2
            let steps = 28
            for i in 0...steps {
                let f = CGFloat(i) / CGFloat(steps)
                let a = f * turns * .pi * 2 + t * 9 * side
                let r = f * 0.13 * R
                let pt = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            ctx.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: max(0.8, 0.045 * R), lineCap: .round))
        }
    }

    // MARK: Значок «!»

    private func drawBadge(_ ctx: GraphicsContext, cx: CGFloat, cy: CGFloat, R: CGFloat) {
        let s = badge.value
        guard s > 0.02 else { return }
        let color = state == .error ? Color(hex: "#F4505E") : Color(hex: "#FFB020")
        let r = 0.3 * R * s
        let c = CGPoint(x: cx + 0.95 * R, y: cy - 1.25 * R + sin(t * 6) * 0.04 * R)
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(color))
        let bar = CGRect(x: c.x - 0.045 * R * s, y: c.y - 0.17 * R * s, width: 0.09 * R * s, height: 0.21 * R * s)
        ctx.fill(Path(roundedRect: bar, cornerRadius: 0.04 * R * s), with: .color(.white))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 0.05 * R * s, y: c.y + 0.08 * R * s, width: 0.1 * R * s, height: 0.1 * R * s)),
                 with: .color(.white))
    }

    // MARK: Частицы

    private func drawParticles(_ ctx: GraphicsContext, cx: CGFloat, cy: CGFloat, R: CGFloat, behind: Bool) {
        let pal = variant.palette
        for p in particles where (p.kind == .ember) == behind {
            let f = p.age / p.life
            let alpha = Double(f < 0.2 ? f / 0.2 : (1 - f) / 0.8)
            let x = cx + p.x * R
            let y = cy + p.y * R
            let s = p.size * R * (p.kind == .ember ? (1 - f * 0.5) : 1)
            switch p.kind {
            case .ember:
                ctx.fill(Path(ellipseIn: CGRect(x: x - s, y: y - s, width: s * 2, height: s * 2)),
                         with: .color(pal.core.opacity(alpha * 0.9)))
            case .spark:
                var c = ctx
                c.translateBy(x: x, y: y)
                c.rotate(by: .radians(Double(p.rot)))
                c.fill(sparkle(s), with: .color((Int(p.rot * 10) % 2 == 0 ? pal.core : Color(hex: "#FFD866")).opacity(alpha)))
            }
        }
    }

    private func sparkle(_ s: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0, y: -s))
        p.addQuadCurve(to: CGPoint(x: s, y: 0), control: .zero)
        p.addQuadCurve(to: CGPoint(x: 0, y: s), control: .zero)
        p.addQuadCurve(to: CGPoint(x: -s, y: 0), control: .zero)
        p.addQuadCurve(to: CGPoint(x: 0, y: -s), control: .zero)
        p.closeSubpath()
        return p
    }
}

// MARK: - Цвет из hex

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt64(h, radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}
