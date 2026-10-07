"""XFriend brain: loads every model once, then talks through the face forever.

    uv run python -m brain.main
"""

from __future__ import annotations

import asyncio
import logging
import time
from pathlib import Path

from . import config, logs
from .face_link import FaceLink
from .llm import LLM
from .pipeline import Pipeline
from .stt import Whisper
from .tts import Kokoro
from .vad import Endpointer, SileroVAD

log = logging.getLogger("main")

MODELS_DIR = Path(__file__).resolve().parent.parent / "models"


async def timed(label: str, fn, *args):
    start = time.perf_counter()
    result = await asyncio.to_thread(fn, *args) if not asyncio.iscoroutinefunction(fn) else await fn(*args)
    log.info("%s ready in %.1fs", label, time.perf_counter() - start)
    return result


async def main() -> None:
    logs.setup("main", console_level=logging.INFO)
    cfg = config.load()
    voice = cfg.raw.get("voice", {})
    vad_cfg = cfg.raw.get("vad", {})
    log.info("starting brain (model %s, voice %s, humor %s)", cfg.model, voice.get("name", "af_heart"), cfg.humor)

    missing = [f for f in ("silero_vad.onnx", "kokoro-v1.0.onnx", "voices-v1.0.bin") if not (MODELS_DIR / f).exists()]
    if missing:
        raise SystemExit(f"missing model files in {MODELS_DIR}: {', '.join(missing)} (see README, Setup)")

    endpointer = Endpointer(
        SileroVAD(MODELS_DIR / "silero_vad.onnx"),
        threshold=float(vad_cfg.get("threshold", 0.5)),
        silence_ms=int(vad_cfg.get("silence_ms", 600)),
        min_speech_ms=int(vad_cfg.get("min_speech_ms", 250)),
    )
    stt = Whisper(voice.get("stt_model", "mlx-community/whisper-small.en-mlx"), voice.get("language", "en"))
    await timed("whisper", stt.warm_up)
    tts = Kokoro(MODELS_DIR, voice=voice.get("name", "af_heart"), speed=float(voice.get("speed", 1.0)))
    await timed("kokoro", tts.warm_up)
    llm = LLM(cfg)
    await timed("llm", llm.complete, [{"role": "user", "content": "Say hi."}])

    face = FaceLink(cfg.face_host, cfg.face_port)
    Pipeline(cfg, face, llm, endpointer, stt, tts)
    log.info("waiting for the face on %s:%d", cfg.face_host, cfg.face_port)
    await face.run()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print()
