"""Speech detection with Silero VAD (ONNX, no torch) and an end-of-turn endpointer."""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import onnxruntime as ort

SAMPLE_RATE = 16_000
WINDOW = 512          # Silero v5 expects 512-sample windows at 16 kHz (32 ms)
CONTEXT = 64          # ...with the previous 64 samples prepended
WINDOW_MS = WINDOW * 1000 // SAMPLE_RATE


class SileroVAD:
    def __init__(self, model_path: Path) -> None:
        opts = ort.SessionOptions()
        opts.inter_op_num_threads = 1
        opts.intra_op_num_threads = 1
        self.session = ort.InferenceSession(str(model_path), sess_options=opts, providers=["CPUExecutionProvider"])
        self.reset()

    def reset(self) -> None:
        self._state = np.zeros((2, 1, 128), dtype=np.float32)
        self._context = np.zeros((1, CONTEXT), dtype=np.float32)

    def prob(self, window: np.ndarray) -> float:
        """Speech probability for one 512-sample float32 window in [-1, 1]."""
        x = np.concatenate([self._context, window.reshape(1, -1)], axis=1)
        out, self._state = self.session.run(
            None, {"input": x, "state": self._state, "sr": np.array(SAMPLE_RATE, dtype=np.int64)}
        )
        self._context = x[:, -CONTEXT:]
        return float(out[0][0])


@dataclass
class VADEvent:
    kind: str                      # "start" (user began talking) or "end" (utterance complete)
    audio: np.ndarray | None = None  # float32 16 kHz, only on "end"


class Endpointer:
    """Turns a stream of 16 kHz int16 PCM into speech start / end-of-utterance events.

    "start" fires once speech has lasted `min_speech_ms` (so a cough doesn't barge in);
    "end" fires after `silence_ms` of quiet and carries the whole utterance, including
    a little pre-roll so the first syllable isn't clipped.
    """

    def __init__(self, vad: SileroVAD, threshold: float = 0.5, silence_ms: int = 600,
                 min_speech_ms: int = 250, preroll_ms: int = 300, max_utterance_s: float = 30.0) -> None:
        self.vad = vad
        self.on = threshold
        self.off = max(0.1, threshold - 0.15)
        self.silence_windows = silence_ms // WINDOW_MS
        self.min_speech_windows = max(1, min_speech_ms // WINDOW_MS)
        self.max_windows = int(max_utterance_s * 1000 / WINDOW_MS)
        # +1: the window that triggered speech, plus preroll_ms of audio before it
        self._preroll: deque[np.ndarray] = deque(maxlen=preroll_ms // WINDOW_MS + 1)
        self._pending = np.zeros(0, dtype=np.float32)
        self.reset()

    def reset(self) -> None:
        self.vad.reset()
        self._preroll.clear()
        self._pending = np.zeros(0, dtype=np.float32)
        self._utterance: list[np.ndarray] = []
        self._in_speech = False
        self._started = False
        self._speech_run = 0
        self._silence_run = 0

    @property
    def in_speech(self) -> bool:
        return self._in_speech

    def feed(self, pcm16: bytes) -> list[VADEvent]:
        samples = np.frombuffer(pcm16, dtype="<i2").astype(np.float32) / 32768.0
        self._pending = np.concatenate([self._pending, samples])
        events: list[VADEvent] = []
        while len(self._pending) >= WINDOW:
            window, self._pending = self._pending[:WINDOW], self._pending[WINDOW:]
            event = self._step(window)
            if event:
                events.append(event)
        return events

    def _step(self, window: np.ndarray) -> VADEvent | None:
        p = self.vad.prob(window)
        if not self._in_speech:
            self._preroll.append(window)
            if p >= self.on:
                self._in_speech = True
                self._utterance = list(self._preroll)
                self._speech_run = 1
                self._silence_run = 0
            return None

        self._utterance.append(window)
        if p >= self.off:
            self._speech_run += 1
            self._silence_run = 0
        else:
            self._silence_run += 1

        event = None
        if not self._started and self._speech_run >= self.min_speech_windows:
            self._started = True
            event = VADEvent("start")

        if self._silence_run >= self.silence_windows or len(self._utterance) >= self.max_windows:
            started, utterance = self._started, self._utterance
            self._in_speech = False
            self._started = False
            self._utterance = []
            self._preroll.clear()
            if started:  # too-short blips are dropped silently
                return VADEvent("end", np.concatenate(utterance))
        return event
