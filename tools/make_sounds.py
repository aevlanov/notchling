#!/usr/bin/env python3
"""Генерирует звуки Notchling кодом (без чужих сэмплов).

    python3 tools/make_sounds.py          → Resources/sounds/*.wav

Стиль: мягкие «стеклянные» колокольчики, пузырьковые глиссандо и тёплый шорох огня.
"""
import os
import wave
import numpy as np

SR = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "Resources", "sounds")
rng = np.random.default_rng(7)


def t_axis(dur):
    return np.arange(int(SR * dur)) / SR


def env(n, attack=0.005, decay=0.25, curve=1.0):
    """Быстрая атака + экспоненциальное затухание."""
    t = np.arange(n) / SR
    a = np.clip(t / max(attack, 1e-4), 0, 1)
    d = np.exp(-t / decay) ** curve
    return a * d


def bell(freq, dur=0.6, decay=0.22, bright=0.35):
    """Мягкий колокольчик: основной тон + негармонические обертоны, которые гаснут быстрее."""
    t = t_axis(dur)
    n = len(t)
    s = np.sin(2 * np.pi * freq * t) * env(n, 0.003, decay)
    s += bright * 0.5 * np.sin(2 * np.pi * freq * 2.01 * t) * env(n, 0.002, decay * 0.45)
    s += bright * 0.22 * np.sin(2 * np.pi * freq * 3.98 * t) * env(n, 0.001, decay * 0.25)
    s += 0.12 * np.sin(2 * np.pi * (freq * 1.003) * t) * env(n, 0.003, decay)  # лёгкий хорус
    return s


def glide(f0, f1, dur, decay=0.18, shape="exp", vib=0.0, vib_rate=0.0, wave_kind="sine"):
    """Пузырьковое глиссандо f0 → f1."""
    t = t_axis(dur)
    n = len(t)
    if shape == "exp":
        f = f0 * (f1 / f0) ** (t / dur)
    else:
        f = f0 + (f1 - f0) * (t / dur)
    if vib:
        f = f * (1 + vib * np.sin(2 * np.pi * vib_rate * t))
    ph = 2 * np.pi * np.cumsum(f) / SR
    if wave_kind == "tri":
        s = 2 / np.pi * np.arcsin(np.sin(ph))
    else:
        s = np.sin(ph) + 0.15 * np.sin(2 * ph)
    return s * env(n, 0.004, decay)


def whoosh(dur=0.35, lo=300, hi=2200, amp=0.5):
    """Шорох огня: шум через плавающий полосовой фильтр, нарастание и спад."""
    n = int(SR * dur)
    noise = rng.standard_normal(n)
    # простой однополюсный ФНЧ с плавающей частотой
    out = np.zeros(n)
    y = 0.0
    for i in range(n):
        p = i / n
        fc = lo + (hi - lo) * np.sin(np.pi * p) ** 1.5
        a = 1 - np.exp(-2 * np.pi * fc / SR)
        y += a * (noise[i] - y)
        out[i] = y
    out -= np.convolve(out, np.ones(64) / 64, mode="same")  # убираем гул
    shape = np.sin(np.pi * np.linspace(0, 1, n)) ** 2
    return out * shape * amp


def crackle(dur=0.4, count=6, amp=0.25):
    """Потрескивание: короткие щелчки-искорки."""
    n = int(SR * dur)
    s = np.zeros(n)
    for _ in range(count):
        i = rng.integers(0, n - 400)
        k = np.arange(300)
        s[i:i + 300] += rng.uniform(0.4, 1) * np.sin(2 * np.pi * rng.uniform(2500, 5000) * k / SR) * np.exp(-k / 40)
    return s * amp


def place(total, *parts):
    """Склеивает (сдвиг_в_секундах, сигнал, громкость)."""
    n = int(SR * total)
    out = np.zeros(n)
    for off, sig, g in parts:
        i = int(SR * off)
        j = min(n, i + len(sig))
        out[i:j] += sig[:j - i] * g
    return out


def reverb(x, mix=0.18):
    """Небольшая комната: несколько затухающих задержек."""
    out = x.copy()
    for ms, g in [(23, 0.5), (37, 0.42), (53, 0.33), (79, 0.25), (113, 0.18), (157, 0.12)]:
        d = int(SR * ms / 1000)
        delayed = np.zeros_like(x)
        delayed[d:] = x[:-d]
        out += mix * g * delayed
    return out


def finish(x, peak_db=-4.0, fade=0.02):
    x = reverb(x)
    n = int(SR * fade)
    x[-n:] *= np.linspace(1, 0, n)
    peak = np.max(np.abs(x)) or 1
    return x / peak * (10 ** (peak_db / 20))


def write(name, x):
    os.makedirs(OUT, exist_ok=True)
    data = (np.clip(x, -1, 1) * 32767).astype(np.int16)
    with wave.open(os.path.join(OUT, name + ".wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data.tobytes())


# Ноты
C5, D5, E5, G5, A5 = 523.25, 587.33, 659.25, 783.99, 880.0
C6, D6, E6, G6, A6, C7 = 1046.5, 1174.66, 1318.5, 1567.98, 1760.0, 2093.0

SOUNDS = {
    # Привет: огонёк вспыхивает — шорох + три восходящих колокольчика
    "greet": lambda: place(1.0, (0, whoosh(0.3, 400, 1800, 0.35), 1),
                           (0.08, bell(G5, 0.5), 0.5), (0.18, bell(C6, 0.5), 0.5), (0.28, bell(E6, 0.7, 0.3), 0.55)),
    # Claude начал работу: мягкое «фух» и тихий тон
    "work": lambda: place(0.45, (0, whoosh(0.35, 250, 1400, 0.5), 1), (0.05, glide(330, 440, 0.3, 0.12), 0.25)),
    # Нужно разрешение: два внимательных колокольчика, вверх
    "approval": lambda: place(0.9, (0, bell(E6, 0.5, 0.18, 0.5), 0.6), (0.16, bell(A6, 0.7, 0.26, 0.5), 0.65),
                              (0.0, crackle(0.3, 4, 0.2), 1)),
    # Разрешено: пузырёк вверх + звёздочка
    "approve": lambda: place(0.6, (0, glide(480, 980, 0.18, 0.1), 0.6), (0.12, bell(C7, 0.45, 0.16, 0.2), 0.35)),
    # Свернуть/отклонить: пузырёк вниз
    "close": lambda: place(0.35, (0, glide(760, 380, 0.2, 0.08), 0.55)),
    # Развернуть: короткий тёплый «поп»
    "open": lambda: place(0.3, (0, glide(420, 640, 0.09, 0.06), 0.55), (0.02, whoosh(0.15, 600, 2600, 0.25), 1)),
    # Готово: радостное арпеджио + искорки
    "finish": lambda: place(1.4, (0, bell(C6, 0.5, 0.18), 0.45), (0.09, bell(E6, 0.5, 0.18), 0.45),
                            (0.18, bell(G6, 0.6, 0.22), 0.45), (0.27, bell(C7, 1.0, 0.4, 0.25), 0.5),
                            (0.3, crackle(0.6, 7, 0.18), 1)),
    # Ошибка: мягкое «бвомп» вниз (без резкости)
    "error": lambda: place(0.7, (0, glide(330, 220, 0.25, 0.14, wave_kind="tri"), 0.6),
                           (0.18, glide(262, 165, 0.35, 0.2, wave_kind="tri"), 0.55)),
    # Тык: «бойнг»
    "slap": lambda: place(0.45, (0, glide(520, 300, 0.4, 0.14, vib=0.08, vib_rate=18), 0.6)),
    # Закружилась голова: волнистое падение
    "dizzy": lambda: place(1.0, (0, glide(900, 260, 0.9, 0.35, vib=0.12, vib_rate=7), 0.5),
                           (0.0, crackle(0.8, 5, 0.12), 1)),
}

if __name__ == "__main__":
    for name, make in SOUNDS.items():
        write(name, finish(make()))
        print("  ", name + ".wav")
