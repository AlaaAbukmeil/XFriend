"""The voice loop: mic audio -> VAD -> Whisper -> LLM -> Kokoro -> face.

Every stage streams into the next: each finished LLM sentence is synthesized and sent
while the LLM keeps generating, so the robot starts talking ~1 s after you stop.
"""

from __future__ import annotations

import asyncio
import logging
import re
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np

from .config import Config
from .face_link import FaceLink
from .llm import LLM, Sentence, system_prompt
from .protocol import TTS_SAMPLE_RATE, Frame, Msg
from .stt import Whisper
from .tts import Kokoro
from .vad import Endpointer, VADEvent

log = logging.getLogger("pipeline")

MAX_TURNS = 20

# Spoken commands handled before the LLM sees the text.
HUMOR_COMMANDS = [
    (re.compile(r"\b(keep it clean|be nice|guests are (here|over|coming))\b", re.I), "clean"),
    (re.compile(r"\b(back to normal|normal mode)\b", re.I), "normal"),
    (re.compile(r"\b(go unhinged|no filter|unhinged mode)\b", re.I), "unhinged"),
]


class Pipeline:
    def __init__(self, cfg: Config, face: FaceLink, llm: LLM, endpointer: Endpointer,
                 stt: Whisper, tts: Kokoro) -> None:
        self.cfg = cfg
        self.face = face
        self.llm = llm
        self.endpointer = endpointer
        self.stt = stt
        self.tts = tts
        voice = cfg.raw.get("voice", {})
        self.barge_in = bool(voice.get("barge_in", True))
        self.greet_on_connect = bool(cfg.raw.get("greet_on_connect", True))
        self.conversation_timeout = float(cfg.raw.get("conversation_timeout_s", 120))

        self.history: list[dict] = []
        self.state = "idle"
        self.turn_task: asyncio.Task | None = None
        self.last_activity = 0.0
        self._speaking_until = 0.0
        self._mood_timers: list[asyncio.TimerHandle] = []
        # One thread each, so STT and TTS never fight over a model.
        self._stt_pool = ThreadPoolExecutor(1, thread_name_prefix="stt")
        self._tts_pool = ThreadPoolExecutor(1, thread_name_prefix="tts")
        face.on_frame(self.on_frame)

    # ---- inputs -------------------------------------------------------------

    async def on_frame(self, frame: Frame) -> None:
        if frame.type == Msg.MIC_AUDIO:
            for event in self.endpointer.feed(frame.payload):
                await self.on_vad(event)
        elif frame.type == Msg.HELLO:
            self.endpointer.reset()
            self.state = ""  # force a resend: the face just (re)started
            await self.set_state("listening")
            if self.greet_on_connect and not self.busy:
                note = (f"(Your face app just connected, so you can see and hear {self.cfg.user_name} again. "
                        "Greet them in one short line.)")
                self.turn_task = asyncio.create_task(self.turn(prompt=note))
        elif frame.type == Msg.TOUCH:
            info = frame.json()
            log.info("touch: %s", info)
            if info.get("kind") == "mute_toggle":
                self.endpointer.reset()

    async def on_vad(self, event: VADEvent) -> None:
        if event.kind == "start":
            if self.busy and self.barge_in:
                await self.interrupt()
            return
        # End of an utterance.
        if self.busy:
            if not self.barge_in:
                log.info("ignored speech while busy (barge_in off)")
                return
            await self.interrupt()
        self.turn_task = asyncio.create_task(self.turn(audio=event.audio, ended_at=time.monotonic()))

    @property
    def busy(self) -> bool:
        return self.turn_task is not None and not self.turn_task.done()

    # ---- outputs ------------------------------------------------------------

    async def set_state(self, state: str) -> None:
        if state != self.state:
            self.state = state
            await self.face.state(state)

    async def interrupt(self) -> None:
        log.info("barge-in: stopping speech")
        if self.turn_task and not self.turn_task.done():
            self.turn_task.cancel()
            try:
                await self.turn_task
            except asyncio.CancelledError:
                pass
        await self.face.stop()
        self._cancel_moods()
        self._speaking_until = 0.0
        await self.set_state("listening")

    def _cancel_moods(self) -> None:
        for timer in self._mood_timers:
            timer.cancel()
        self._mood_timers.clear()

    def _schedule_mood(self, mood: str, at: float) -> None:
        """Change the eyes when this sentence's audio actually starts playing."""
        delay = max(0.0, at - time.monotonic())
        loop = asyncio.get_running_loop()
        self._mood_timers.append(loop.call_later(delay, lambda: asyncio.create_task(self.face.mood(mood))))

    # ---- one turn -----------------------------------------------------------

    async def turn(self, audio: np.ndarray | None = None, prompt: str | None = None,
                   ended_at: float | None = None) -> None:
        loop = asyncio.get_running_loop()
        ended_at = ended_at or time.monotonic()
        timings: dict[str, float] = {}
        spoken: list[str] = []
        user_text = prompt or ""
        try:
            await self.set_state("thinking")
            if audio is not None:
                user_text = await loop.run_in_executor(self._stt_pool, self.stt.transcribe, audio)
                timings["stt"] = time.monotonic() - ended_at
                if not user_text:
                    log.info("heard nothing meaningful (%.1fs of audio)", len(audio) / 16_000)
                    await self.set_state("listening")
                    return
                log.info("heard: %s", user_text)
                self._apply_commands(user_text)

            self._maybe_new_conversation()
            self.history.append({"role": "user", "content": user_text})
            messages = [{"role": "system", "content": system_prompt(self.cfg)}] + self.history[-MAX_TURNS * 2:]

            queue: asyncio.Queue[Sentence | None] = asyncio.Queue()

            async def produce() -> None:
                try:
                    async for sentence in self.llm.sentences(messages):
                        if "llm" not in timings:
                            timings["llm"] = time.monotonic() - ended_at
                        await queue.put(sentence)
                finally:
                    await queue.put(None)

            async def consume() -> None:
                while (sentence := await queue.get()) is not None:
                    pcm = await loop.run_in_executor(self._tts_pool, self.tts.synthesize, sentence.text, sentence.mood)
                    if not pcm:
                        continue
                    now = time.monotonic()
                    start_at = max(now, self._speaking_until)
                    self._schedule_mood(sentence.mood, start_at)
                    if "first_audio" not in timings:
                        timings["first_audio"] = now - ended_at
                        await self.set_state("speaking")
                    await self.face.tts_audio(pcm)
                    self._speaking_until = start_at + len(pcm) / 2 / TTS_SAMPLE_RATE
                    spoken.append(f"[{sentence.mood}] {sentence.text}")
                    log.info("said [%s] %s", sentence.mood, sentence.text)

            await asyncio.gather(produce(), consume())
            # Stay in "speaking" until the face has actually finished playing.
            await asyncio.sleep(max(0.0, self._speaking_until - time.monotonic()))
            await self.set_state("listening")
        except asyncio.CancelledError:
            if spoken:
                spoken.append("(interrupted)")
            raise
        finally:
            if spoken:
                self.history.append({"role": "assistant", "content": " ".join(spoken)})
            self.last_activity = time.monotonic()
            if timings:
                log.info("latency %s", " ".join(f"{k}={v:.2f}s" for k, v in timings.items()))

    def _apply_commands(self, text: str) -> None:
        for pattern, level in HUMOR_COMMANDS:
            if pattern.search(text) and self.cfg.humor != level:
                self.cfg.humor = level
                log.info("humor set to %s by voice", level)

    def _maybe_new_conversation(self) -> None:
        if self.history and time.monotonic() - self.last_activity > self.conversation_timeout:
            log.info("new conversation (idle %.0fs); clearing working memory", time.monotonic() - self.last_activity)
            self.history.clear()
