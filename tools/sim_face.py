"""A pretend face for testing the brain end to end, no human or mic needed.

It listens like the real face app, "says" each line by streaming Kokoro audio as mic
chunks in real time, and reports what the brain did and how fast.

    XFRIEND_FACE_PORT=7799 uv run python -m brain.main      # terminal 1
    uv run python -m tools.sim_face --port 7799           # terminal 2
    uv run python -m tools.sim_face --port 7799 --barge-in
"""

from __future__ import annotations

import argparse
import asyncio
import time
from collections import deque
from pathlib import Path

import numpy as np

from brain.protocol import Frame, FrameDecoder, Msg, encode, encode_json
from brain.tts import Kokoro

LINES = [
    "Hey Gizmo, how's it going?",
    "I'm thinking about learning to play the guitar.",
    "What do you think I should name my new plant?",
]
CHUNK = 320  # 20 ms at 16 kHz


def to_16k(pcm24: bytes) -> np.ndarray:
    x = np.frombuffer(pcm24, dtype="<i2").astype(np.float32)
    n = int(len(x) * 16_000 / 24_000)
    return np.interp(np.linspace(0, len(x) - 1, n), np.arange(len(x)), x).astype("<i2")


class SimFace:
    def __init__(self) -> None:
        self.writer: asyncio.StreamWriter | None = None
        self.connected = asyncio.Event()
        self.events: list[tuple[float, str, str]] = []
        self.tts_bytes = 0
        self.mic_queue: deque[bytes] = deque()

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self.writer = writer
        writer.write(encode_json(Msg.HELLO, {"build_date": "2026-10-06T00:00:00Z", "platform": "sim", "screen": [0, 0]}))
        self.connected.set()
        asyncio.create_task(self.mic_loop())
        dec = FrameDecoder()
        while data := await reader.read(65536):
            for f in dec.feed(data):
                self.on_frame(f)

    def on_frame(self, f: Frame) -> None:
        now = time.monotonic()
        if f.type == Msg.TTS_AUDIO:
            if not self.tts_bytes or self.events[-1][1] != "audio":
                self.events.append((now, "audio", ""))
            self.tts_bytes += len(f.payload)
        elif f.type in (Msg.STATE, Msg.MOOD):
            self.events.append((now, Msg(f.type).name.lower(), next(iter(f.json().values()))))
        elif f.type == Msg.STOP:
            self.events.append((now, "stop", ""))

    async def mic_loop(self) -> None:
        """Like a real mic: a 20 ms chunk every 20 ms, speech if queued, else silence."""
        silence = np.zeros(CHUNK, dtype="<i2").tobytes()
        next_t = time.monotonic()
        while True:
            chunk = self.mic_queue.popleft() if self.mic_queue else silence
            self.writer.write(encode(Msg.MIC_AUDIO, chunk))
            next_t += CHUNK / 16_000
            await asyncio.sleep(max(0, next_t - time.monotonic()))

    async def say(self, pcm16k: np.ndarray) -> float:
        """Queue speech on the mic; return (monotonic) when it has finished playing."""
        for i in range(0, len(pcm16k), CHUNK):
            chunk = pcm16k[i:i + CHUNK]
            self.mic_queue.append(np.pad(chunk, (0, CHUNK - len(chunk))).tobytes())
        await asyncio.sleep(len(pcm16k) / 16_000)
        while self.mic_queue:
            await asyncio.sleep(0.01)
        return time.monotonic()

    async def wait_for_state(self, state: str, after: float, timeout: float = 30) -> float | None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for t, kind, value in self.events:
                if t > after and kind == "state" and value == state:
                    return t
            await asyncio.sleep(0.05)
        return None


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7799)
    ap.add_argument("--barge-in", action="store_true", help="interrupt the robot mid-reply")
    args = ap.parse_args()

    tts = Kokoro(Path(__file__).resolve().parent.parent / "models", voice="am_michael")
    face = SimFace()
    server = await asyncio.start_server(face.handle, "127.0.0.1", args.port)
    print(f"sim face listening on {args.port}; start the brain with XFRIEND_FACE_PORT={args.port}")
    await face.connected.wait()
    print("brain connected; waiting for greeting to finish")
    await face.wait_for_state("listening", after=time.monotonic() + 1, timeout=60)
    await asyncio.sleep(1)

    for line in LINES[:1] if args.barge_in else LINES:
        face.events.clear()
        face.tts_bytes = 0
        print(f"\nyou (simulated): {line}")
        ended = await face.say(to_16k(tts.synthesize(line)))
        if args.barge_in:
            if not await face.wait_for_state("speaking", after=ended):
                print("  robot never started speaking")
                break
            await asyncio.sleep(1.0)
            print("interrupting while it talks...")
            interrupt_at = time.monotonic()
            await face.say(to_16k(tts.synthesize("Wait, hold on.")))
            stop = next((t for t, k, _ in face.events if k == "stop" and t > interrupt_at), None)
            print(f"  stop sent {stop - interrupt_at:.2f}s after I started talking" if stop else "  stop NEVER sent")
            ended = time.monotonic()
        done = await face.wait_for_state("listening", after=ended + 0.1, timeout=40)
        first_audio = next((t for t, k, _ in face.events if k == "audio" and t > ended), None)
        moods = [v for t, k, v in face.events if k == "mood" and t > ended]
        print(f"  first audio {first_audio - ended:.2f}s after speech ended" if first_audio else "  no audio!")
        print(f"  reply {face.tts_bytes / 2 / 24_000:.1f}s of speech total, moods {moods}, back to listening: {bool(done)}")
        await asyncio.sleep(0.5)

    server.close()
    print("\nsee ~/XFriendData/logs/brain.log for what was heard and said")


if __name__ == "__main__":
    asyncio.run(main())
