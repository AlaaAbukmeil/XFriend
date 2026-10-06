"""Ollama streaming chat + mood-tag sentence splitting."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import AsyncIterator

import ollama

from .config import Config

MOODS = ("neutral", "happy", "sarcastic", "sleepy", "surprised", "thinking", "excited", "sad", "angry")

HUMOR_RULES = {
    "clean": "Humor level: CLEAN. Guests may be around. No swearing, no dark or sexual jokes. Stay playful.",
    "normal": "Humor level: NORMAL. Swearing and dark humor are fine when they land; don't force them.",
    "unhinged": "Humor level: UNHINGED. Go all in on profanity, absurdity and dark humor. Still respect the off-limits list.",
}

_TAG = re.compile(r"\[(\w+)\]\s*")
# End of a sentence: terminal punctuation followed by whitespace, or a newline.
_SENTENCE_END = re.compile(r"(?<=[.!?…])[\"')\]]*\s+|\n+")
_THINK = re.compile(r"<think>.*?</think>\s*", re.S)


@dataclass
class Sentence:
    mood: str
    text: str


def system_prompt(cfg: Config, memories: list[str] | None = None) -> str:
    parts = [cfg.persona.replace("{user_name}", cfg.user_name), HUMOR_RULES.get(cfg.humor, HUMOR_RULES["normal"])]
    if memories:
        parts.append("# Things you remember\n" + "\n".join(f"- {m}" for m in memories))
    return "\n\n".join(parts)


def split_tagged(text: str, default_mood: str) -> list[Sentence]:
    """Split one chunk of text on mood tags. Unknown tags fall back to the current mood."""
    out: list[Sentence] = []
    mood = default_mood
    pos = 0
    for m in _TAG.finditer(text):
        before = text[pos:m.start()].strip()
        if before:
            out.append(Sentence(mood, before))
        tag = m.group(1).lower()
        mood = tag if tag in MOODS else mood
        pos = m.end()
    rest = text[pos:].strip()
    if rest:
        out.append(Sentence(mood, rest))
    return out


class SentenceStream:
    """Turns a token stream into complete mood-tagged sentences as early as possible."""

    def __init__(self, mood: str = "neutral") -> None:
        self.mood = mood
        self._buf = ""

    def feed(self, token: str) -> list[Sentence]:
        self._buf += token
        out: list[Sentence] = []
        while True:
            m = _SENTENCE_END.search(self._buf)
            if not m:
                break
            chunk, self._buf = self._buf[:m.end()], self._buf[m.end():]
            out.extend(self._emit(chunk))
        return out

    def flush(self) -> list[Sentence]:
        chunk, self._buf = self._buf, ""
        return self._emit(chunk)

    def _emit(self, chunk: str) -> list[Sentence]:
        sentences = [s for s in split_tagged(chunk, self.mood) if s.text]
        if sentences:
            self.mood = sentences[-1].mood
        return sentences


class LLM:
    def __init__(self, cfg: Config) -> None:
        self.cfg = cfg
        self.client = ollama.AsyncClient()

    async def stream(self, messages: list[dict], model: str | None = None) -> AsyncIterator[str]:
        """Yield raw text tokens. Thinking is disabled; any stray <think> block is stripped."""
        in_think = False
        async for part in await self.client.chat(
            model=model or self.cfg.model,
            messages=messages,
            stream=True,
            think=False,
            keep_alive="24h",
            options={"temperature": 0.9, "num_predict": 300},
        ):
            token = part.message.content or ""
            # Fallback for models that ignore think=False.
            if "<think>" in token:
                in_think = True
            if in_think:
                if "</think>" in token:
                    in_think = False
                    token = token.split("</think>", 1)[1]
                else:
                    continue
            if token:
                yield token

    async def sentences(self, messages: list[dict], model: str | None = None) -> AsyncIterator[Sentence]:
        stream = SentenceStream()
        async for token in self.stream(messages, model):
            for s in stream.feed(token):
                yield s
        for s in stream.flush():
            yield s

    async def complete(self, messages: list[dict], model: str | None = None, fmt: str | None = None) -> str:
        """Non-streaming call, used for memory extraction and summaries."""
        resp = await self.client.chat(
            model=model or self.cfg.model, messages=messages, think=False, format=fmt, keep_alive="24h",
        )
        return _THINK.sub("", resp.message.content or "")
