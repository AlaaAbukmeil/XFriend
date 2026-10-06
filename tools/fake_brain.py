"""Drive the face app without any AI, to test eyes, link and audio.

    uv run python -m tools.fake_brain            # cycle every mood and state
    uv run python -m tools.fake_brain --tone     # play a 1 s test tone (playback check)
    uv run python -m tools.fake_brain --echo     # record 3 s of mic, play it back (loopback)
    uv run python -m tools.fake_brain --stop     # start a long tone, then send stop after 1 s
"""

from __future__ import annotations

import argparse
import asyncio
import math
import struct

import numpy as np

from brain import logs
from brain.face_link import FaceLink
from brain.llm import MOODS
from brain.protocol import MIC_SAMPLE_RATE, TTS_SAMPLE_RATE, Frame, Msg

STATES = ("idle", "listening", "thinking", "speaking")


def tone(seconds: float, freq: float = 440.0) -> bytes:
    n = int(TTS_SAMPLE_RATE * seconds)
    fade = int(TTS_SAMPLE_RATE * 0.01)
    samples = []
    for i in range(n):
        env = min(1.0, i / fade, (n - i) / fade)
        samples.append(int(0.3 * env * 32767 * math.sin(2 * math.pi * freq * i / TTS_SAMPLE_RATE)))
    return struct.pack(f"<{n}h", *samples)


def resample(pcm16: bytes, src: int, dst: int) -> bytes:
    x = np.frombuffer(pcm16, dtype="<i2").astype(np.float32)
    n = int(len(x) * dst / src)
    y = np.interp(np.linspace(0, len(x) - 1, n), np.arange(len(x)), x)
    return y.astype("<i2").tobytes()


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=7777)
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--tone", action="store_true")
    mode.add_argument("--echo", action="store_true")
    mode.add_argument("--stop", action="store_true")
    args = ap.parse_args()
    logs.setup("fake_brain")

    face = FaceLink(port=args.port)
    mic = bytearray()
    recording = asyncio.Event()

    def on_frame(f: Frame) -> None:
        if f.type == Msg.MIC_AUDIO and recording.is_set():
            mic.extend(f.payload)
        elif f.type == Msg.TOUCH:
            print("touch:", f.json())

    face.on_frame(on_frame)
    asyncio.create_task(face.run())
    print(f"waiting for face on localhost:{args.port} ...")
    await face.connected.wait()
    await asyncio.sleep(0.2)
    print("face hello:", face.hello)

    if args.tone:
        await face.state("speaking")
        await face.tts_audio(tone(1.0))
        await asyncio.sleep(1.2)
        await face.state("idle")
    elif args.stop:
        await face.state("speaking")
        await face.tts_audio(tone(5.0, 330))
        await asyncio.sleep(1.0)
        await face.stop()
        await face.state("idle")
        print("sent stop; tone should have cut off at ~1 s")
    elif args.echo:
        await face.state("listening")
        print("recording 3 s, say something ...")
        recording.set()
        await asyncio.sleep(3.0)
        recording.clear()
        secs = len(mic) / 2 / MIC_SAMPLE_RATE
        peak = int(np.abs(np.frombuffer(bytes(mic), dtype="<i2")).max()) if mic else 0
        print(f"got {secs:.2f} s of mic audio (peak {peak}), playing back")
        await face.state("speaking")
        await face.tts_audio(resample(bytes(mic), MIC_SAMPLE_RATE, TTS_SAMPLE_RATE))
        await asyncio.sleep(secs + 0.3)
        await face.state("idle")
    else:
        for state in STATES:
            print("state:", state)
            await face.state(state)
            await asyncio.sleep(2.0)
        await face.state("idle")
        for mood in MOODS:
            print("mood:", mood)
            await face.mood(mood)
            await asyncio.sleep(2.0)
        await face.mood("neutral")


if __name__ == "__main__":
    asyncio.run(main())
