#!/usr/bin/env python3
"""Synthesize Kliq's keystroke samples.

For each sound profile (creamy, thock, pop, clicky, typewriter) writes 9 WAV
files (soft_1..3, medium_1..3, hard_1..3) into Sounds/<profile>/, as 48 kHz,
mono, 16-bit PCM, ~120 ms each. Every sound is built from:

  1. a noise tick (the switch/keycap contact),
  2. a damped "body" resonance (the case/plate ringing), optionally with a
     falling pitch (pop) or an inharmonic overtone (typewriter),
  3. a smaller bottom-out hit 6-10 ms after the tick,
  4. optionally a sharp extra click (clicky switches).

Within a profile, hard sounds get a deeper, louder body and soft sounds a
brighter, lighter one. Each variant gets a small random pitch shift (+/-4%)
so repeats don't sound robotic. Output is deterministic (fixed seed).

Usage:
    python3 tools/make_sounds.py [sounds_dir]

Requires numpy.
"""

import sys
import wave
from pathlib import Path

import numpy as np

SAMPLE_RATE = 48_000
DURATION = 0.120
VARIANTS = 3
SEED = 20260930

# Defaults shared by every layer; profiles override what they need.
# Frequencies in Hz, times in seconds.
BASE = dict(
    body_freq=400.0, body_freq2=1000.0, body2_level=0.20, body_tau=0.012, body_level=0.9,
    sweep=1.0,
    tick_level=0.30, tick_tau=0.0009, tick_brightness=0.2,
    click_level=0.0, click_delay=0.0025,
    bottom_delay=0.008, bottom_freq=200.0, bottom_tau=0.007, bottom_level=0.4,
    tone_cutoff=4000.0, peak=0.3,
)


def layers(soft: dict, medium: dict, hard: dict) -> dict:
    return {name: {**BASE, **params} for name, params in
            (("soft", soft), ("medium", medium), ("hard", hard))}


PROFILES = {
    # Deep, muted and quiet. The default.
    "creamy": layers(
        dict(body_freq=330, body_freq2=700, body_tau=0.010, tick_level=0.15, tick_brightness=0.1,
             bottom_freq=180, bottom_level=0.3, tone_cutoff=2600, peak=0.20),
        dict(body_freq=260, body_freq2=560, body_tau=0.013, tick_level=0.15, tick_brightness=0.1,
             bottom_freq=150, bottom_level=0.4, tone_cutoff=2200, peak=0.30),
        dict(body_freq=190, body_freq2=450, body_tau=0.018, tick_level=0.15, tick_brightness=0.1,
             bottom_freq=110, bottom_level=0.55, tone_cutoff=1900, peak=0.42),
    ),
    # Solid thock with a little more attack.
    "thock": layers(
        dict(body_freq=520, body_freq2=1150, body_tau=0.008, body_level=0.70,
             tick_level=0.35, tick_tau=0.0008, tick_brightness=0.25,
             bottom_delay=0.0065, bottom_freq=260, bottom_tau=0.005, bottom_level=0.25,
             tone_cutoff=5000, peak=0.22),
        dict(body_freq=360, body_freq2=900, body_tau=0.011, body_level=0.90,
             tick_level=0.30, tick_tau=0.0009, tick_brightness=0.20,
             bottom_delay=0.0080, bottom_freq=190, bottom_tau=0.007, bottom_level=0.40,
             tone_cutoff=4000, peak=0.34),
        dict(body_freq=240, body_freq2=620, body_tau=0.015, body_level=1.00,
             tick_level=0.28, tick_tau=0.0010, tick_brightness=0.15,
             bottom_delay=0.0095, bottom_freq=130, bottom_tau=0.010, bottom_level=0.55,
             tone_cutoff=3200, peak=0.46),
    ),
    # Rounded bubble-like pop: falling pitch, almost no noise.
    "pop": layers(
        dict(body_freq=700, body2_level=0.05, body_tau=0.012, sweep=1.8, tick_level=0.05,
             bottom_level=0.1, tone_cutoff=3000, peak=0.20),
        dict(body_freq=560, body2_level=0.05, body_tau=0.014, sweep=1.8, tick_level=0.05,
             bottom_level=0.12, tone_cutoff=3000, peak=0.30),
        dict(body_freq=450, body2_level=0.05, body_tau=0.016, sweep=1.8, tick_level=0.05,
             bottom_level=0.15, tone_cutoff=3000, peak=0.40),
    ),
    # Crisp click-jacket switch: sharp click, then a light bottom-out.
    "clicky": layers(
        dict(body_freq=1900, body_freq2=3800, body_tau=0.004, body_level=0.4,
             tick_level=1.0, tick_tau=0.0006, tick_brightness=0.8, click_level=0.8,
             bottom_freq=320, bottom_level=0.25, tone_cutoff=11000, peak=0.22),
        dict(body_freq=1700, body_freq2=3400, body_tau=0.004, body_level=0.45,
             tick_level=1.0, tick_tau=0.0006, tick_brightness=0.8, click_level=0.8,
             bottom_freq=280, bottom_level=0.3, tone_cutoff=11000, peak=0.32),
        dict(body_freq=1500, body_freq2=3000, body_tau=0.005, body_level=0.5,
             tick_level=1.0, tick_tau=0.0007, tick_brightness=0.7, click_level=0.8,
             bottom_freq=240, bottom_level=0.4, tone_cutoff=11000, peak=0.44),
    ),
    # Old typewriter: metallic ring over a heavy thud.
    "typewriter": layers(
        dict(body_freq=1150, body_freq2=1150 * 2.76, body2_level=0.5, body_tau=0.030, body_level=0.5,
             tick_level=0.6, tick_brightness=0.5, bottom_freq=110, bottom_tau=0.012,
             bottom_level=0.8, tone_cutoff=7000, peak=0.25),
        dict(body_freq=1050, body_freq2=1050 * 2.76, body2_level=0.5, body_tau=0.035, body_level=0.5,
             tick_level=0.6, tick_brightness=0.5, bottom_freq=105, bottom_tau=0.012,
             bottom_level=0.9, tone_cutoff=7000, peak=0.36),
        dict(body_freq=950, body_freq2=950 * 2.76, body2_level=0.5, body_tau=0.040, body_level=0.5,
             tick_level=0.6, tick_brightness=0.5, bottom_freq=100, bottom_tau=0.014,
             bottom_level=1.0, tone_cutoff=7000, peak=0.50),
    ),
}


def one_pole_lowpass(x: np.ndarray, cutoff: float) -> np.ndarray:
    """Simple one-pole low-pass filter."""
    a = np.exp(-2.0 * np.pi * cutoff / SAMPLE_RATE)
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc = (1.0 - a) * v + a * acc
        y[i] = acc
    return y


def noise_tick(rng: np.random.Generator, t: np.ndarray, tau: float, brightness: float) -> np.ndarray:
    noise = rng.uniform(-1.0, 1.0, t.size)
    # Blend of high-passed (difference) and band-limited noise sets brightness.
    bright = np.diff(noise, prepend=0.0) * 0.6
    dull = one_pole_lowpass(noise, 3500.0) * 1.6
    tick = brightness * bright + (1.0 - brightness) * dull
    return tick * np.exp(-t / tau)


def damped_sine(t: np.ndarray, freq: float, tau: float, phase: float) -> np.ndarray:
    return np.sin(2.0 * np.pi * freq * t + phase) * np.exp(-t / tau)


def swept_sine(t: np.ndarray, freq: float, tau: float, phase: float, sweep: float) -> np.ndarray:
    """Damped sine whose pitch starts at freq * sweep and settles to freq."""
    glide = 0.010
    cycles = freq * (t + (sweep - 1.0) * glide * (1.0 - np.exp(-t / glide)))
    return np.sin(2.0 * np.pi * cycles + phase) * np.exp(-t / tau)


def delayed(signal: np.ndarray, d: int) -> np.ndarray:
    out = np.zeros_like(signal)
    out[d:] = signal[: signal.size - d]
    return out


def make_sound(rng: np.random.Generator, p: dict, pitch: float) -> np.ndarray:
    n = int(round(SAMPLE_RATE * DURATION))
    t = np.arange(n) / SAMPLE_RATE

    tick = p["tick_level"] * noise_tick(rng, t, p["tick_tau"], p["tick_brightness"])

    # Body: two partials; a fast (0.8 ms) attack keeps it from stepping in.
    attack = np.clip(t / 0.0008, 0.0, 1.0)
    body = (
        swept_sine(t, p["body_freq"] * pitch, p["body_tau"], rng.uniform(0, np.pi), p["sweep"])
        + p["body2_level"] * damped_sine(t, p["body_freq2"] * pitch, p["body_tau"] * 0.6, rng.uniform(0, np.pi))
    ) * attack * p["body_level"]

    # Bottom-out: delayed low thump plus a little noise.
    delay = p["bottom_delay"] * rng.uniform(0.92, 1.08)
    d = int(delay * SAMPLE_RATE)
    tb = t[: n - d]
    bottom_hit = (
        damped_sine(tb, p["bottom_freq"] * pitch, p["bottom_tau"], 0.0)
        + 0.4 * noise_tick(rng, tb, 0.0008, 0.5)
    ) * p["bottom_level"]
    bottom = np.zeros(n)
    bottom[d:] = bottom_hit

    # Optional extra click (clicky switches click before bottoming out).
    click = np.zeros(n)
    if p["click_level"] > 0:
        click = p["click_level"] * delayed(noise_tick(rng, t, 0.0004, 0.9), int(p["click_delay"] * SAMPLE_RATE))

    # A gentle low-pass sets the tone and removes harsh, hissy top end.
    sound = one_pole_lowpass(tick + body + bottom + click, p["tone_cutoff"])

    # Short fade-out so the tail ends at exactly zero.
    fade = int(0.010 * SAMPLE_RATE)
    sound[-fade:] *= np.linspace(1.0, 0.0, fade)

    sound *= p["peak"] / np.max(np.abs(sound))
    return sound


def write_wav(path: Path, samples: np.ndarray) -> None:
    pcm = np.clip(np.round(samples * 32767.0), -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm.tobytes())


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    sounds_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "Kliq" / "Resources" / "Sounds"

    rng = np.random.default_rng(SEED)
    for profile, profile_layers in PROFILES.items():
        out_dir = sounds_dir / profile
        out_dir.mkdir(parents=True, exist_ok=True)
        for layer, params in profile_layers.items():
            for i in range(1, VARIANTS + 1):
                pitch = 1.0 + rng.uniform(-0.04, 0.04)
                write_wav(out_dir / f"{layer}_{i}.wav", make_sound(rng, params, pitch))
        print(f"wrote {profile}: {len(profile_layers) * VARIANTS} files")


if __name__ == "__main__":
    main()
