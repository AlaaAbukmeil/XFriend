"""Terminal text chat with the robot (no audio, no face).

    uv run python -m tools.chat
    uv run python -m tools.chat --model llama3.1:8b
    uv run python -m tools.chat --compare qwen3:8b,llama3.1:8b
    uv run python -m tools.chat --face        # also drive the face app's eyes

Commands: /humor clean|normal|unhinged, /reset, /quit
"""

from __future__ import annotations

import argparse
import asyncio
import logging
import sys
import time

from brain import config, logs
from brain.face_link import FaceLink
from brain.llm import HUMOR_RULES, LLM, system_prompt

MOOD_COLORS = {
    "happy": "32", "excited": "92", "sarcastic": "35", "sleepy": "34", "surprised": "93",
    "thinking": "36", "sad": "94", "angry": "31", "neutral": "37",
}
MAX_TURNS = 20
log = logging.getLogger("chat")


def show(mood: str, text: str) -> None:
    print(f"\033[{MOOD_COLORS.get(mood, '37')}m[{mood}]\033[0m {text}")


async def ainput(prompt: str) -> str:
    return await asyncio.to_thread(input, prompt)


async def reply(llm: LLM, messages: list[dict], model: str, face: FaceLink | None) -> str:
    start = time.perf_counter()
    first: float | None = None
    spoken: list[str] = []
    if face:
        await face.state("thinking")
    async for s in llm.sentences(messages, model):
        if first is None:
            first = time.perf_counter() - start
            if face:
                await face.state("speaking")
        if face:
            await face.mood(s.mood)
        show(s.mood, s.text)
        spoken.append(f"[{s.mood}] {s.text}")
    if face:
        await face.state("listening")
    log.info("reply model=%s first=%.2fs total=%.2fs: %s", model, first or 0, time.perf_counter() - start, " ".join(spoken))
    print(f"\033[90m  {model}: first sentence {first or 0:.2f}s, total {time.perf_counter() - start:.2f}s\033[0m")
    return " ".join(spoken)


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model")
    ap.add_argument("--compare", help="comma-separated models, each answers every message")
    ap.add_argument("--face", action="store_true", help="send moods/states to the face app")
    args = ap.parse_args()

    logs.setup("chat")
    cfg = config.load()
    llm = LLM(cfg)
    models = args.compare.split(",") if args.compare else [args.model or cfg.model]
    histories: dict[str, list[dict]] = {m: [] for m in models}

    face = None
    if args.face:
        face = FaceLink(cfg.face_host, cfg.face_port)
        asyncio.create_task(face.run())

    print(f"Chatting with {', '.join(models)} (humor: {cfg.humor}). /quit to exit.")
    while True:
        try:
            line = (await ainput("\nyou> ")).strip()
        except (EOFError, KeyboardInterrupt):
            break
        if not line:
            continue
        if line == "/quit":
            break
        if line == "/reset":
            histories = {m: [] for m in models}
            print("(history cleared)")
            continue
        if line.startswith("/humor"):
            level = line.split(maxsplit=1)[-1]
            if level in HUMOR_RULES:
                cfg.humor = level
                log.info("humor set to %s", level)
                print(f"(humor: {level})")
            else:
                print(f"(levels: {', '.join(HUMOR_RULES)})")
            continue

        log.info("user: %s", line)
        for model in models:
            history = histories[model]
            history.append({"role": "user", "content": line})
            messages = [{"role": "system", "content": system_prompt(cfg)}] + history[-MAX_TURNS * 2:]
            if len(models) > 1:
                print(f"\033[1m{model}\033[0m")
            try:
                text = await reply(llm, messages, model, face)
            except Exception as e:  # keep the REPL alive on model errors
                log.exception("error from %s", model)
                print(f"error from {model}: {e}", file=sys.stderr)
                history.pop()
                continue
            history.append({"role": "assistant", "content": text})


if __name__ == "__main__":
    asyncio.run(main())
