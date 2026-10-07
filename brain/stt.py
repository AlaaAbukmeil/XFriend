"""Speech to text with mlx-whisper (runs on the Mac GPU)."""

from __future__ import annotations

import logging
import re

import numpy as np

log = logging.getLogger("stt")

# Whisper invents these on near-silence or noise.
_HALLUCINATIONS = {
    "", "you", "thank you", "thanks for watching", "thank you for watching", "bye",
    "subtitles by the amara.org community", "please subscribe",
}


class Whisper:
    def __init__(self, model: str = "mlx-community/whisper-small.en-mlx", language: str | None = "en") -> None:
        import mlx_whisper  # imported lazily: it pulls in MLX, which takes a moment

        self._mlx_whisper = mlx_whisper
        self.model = model
        self.language = language

    def warm_up(self) -> None:
        """Load weights now so the first real turn isn't slow."""
        self.transcribe(np.zeros(16_000, dtype=np.float32))

    def transcribe(self, audio: np.ndarray) -> str:
        """float32 16 kHz mono -> text ('' if nothing meaningful was said)."""
        result = self._mlx_whisper.transcribe(
            audio,
            path_or_hf_repo=self.model,
            language=self.language,
            condition_on_previous_text=False,
            verbose=None,
        )
        text = (result.get("text") or "").strip()
        segments = result.get("segments") or []
        if segments and all(s.get("no_speech_prob", 0) > 0.6 for s in segments):
            return ""
        if re.sub(r"[^\w\s.]", "", text).strip(" .").lower() in _HALLUCINATIONS:
            return ""
        return text
