import AVFoundation
import AppKit

/// Звуки огонька (сгенерированы tools/make_sounds.py): WAV из бандла, по 3 плеера на звук, чтобы звуки могли накладываться.
@MainActor
final class SoundEngine {
    static let shared = SoundEngine()

    var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundEnabled") }
    }
    var volume: Float = 0.22

    private var players: [String: [AVAudioPlayer]] = [:]

    private init() {
        for name in ["greet", "work", "approval", "approve", "close", "open", "finish", "error", "slap", "dizzy"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "sounds") else { continue }
            var pool: [AVAudioPlayer] = []
            for _ in 0..<3 {
                if let p = try? AVAudioPlayer(contentsOf: url) {
                    p.volume = volume
                    p.prepareToPlay()
                    pool.append(p)
                }
            }
            if !pool.isEmpty { players[name] = pool }
        }
    }

    func play(_ name: String) {
        guard enabled, let pool = players[name] else { return }
        let player = pool.first { !$0.isPlaying } ?? pool[0]
        player.currentTime = 0
        player.volume = volume
        player.play()
    }
}
