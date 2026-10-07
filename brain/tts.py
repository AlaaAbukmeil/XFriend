"""Text to speech with Kokoro (ONNX). Output: 24 kHz int16 mono PCM, ready for the face."""

from __future__ import annotations

import re
from pathlib import Path

import numpy as np

# Mood -> speaking speed. The voice stays the same so the robot keeps its identity.
MOOD_SPEED = {
    "excited": 1.12, "happy": 1.05, "surprised": 1.08, "angry": 1.05,
    "sarcastic": 0.97, "thinking": 0.94, "sad": 0.9, "sleepy": 0.85,
}

_UNSPEAKABLE = re.compile(r"[*_#`~<>\[\]{}|]")


class Kokoro:
    SAMPLE_RATE = 24_000

    def __init__(self, models_dir: Path, voice: str = "af_heart", speed: float = 1.0, lang: str = "en-us") -> None:
        from kokoro_onnx import Kokoro as _Kokoro

        self._kokoro = _Kokoro(str(models_dir / "kokoro-v1.0.onnx"), str(models_dir / "voices-v1.0.bin"))
        self.voice = voice
        self.speed = speed
        self.lang = lang

    def voices(self) -> list[str]:
        return sorted(self._kokoro.get_voices())

    def warm_up(self) -> None:
        self.synthesize("Hi.")

    def synthesize(self, text: str, mood: str = "neutral") -> bytes:
        text = _UNSPEAKABLE.sub("", text).strip()
        if not text:
            return b""
        speed = self.speed * MOOD_SPEED.get(mood, 1.0)
        samples, sr = self._kokoro.create(text, voice=self.voice, speed=speed, lang=self.lang)
        if sr != self.SAMPLE_RATE:  # never expected, but keep the wire format honest
            n = int(len(samples) * self.SAMPLE_RATE / sr)
            samples = np.interp(np.linspace(0, len(samples) - 1, n), np.arange(len(samples)), samples)
        return (np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes()
