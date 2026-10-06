"""TCP client that connects the brain to the face app (Mac window or iPad via iproxy).

The face listens; we connect and keep retrying, so either side can restart freely.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Awaitable, Callable

from .protocol import Frame, Msg, ProtocolError, encode, encode_json, read_frame

log = logging.getLogger("face_link")

FrameHandler = Callable[[Frame], Awaitable[None] | None]


class FaceLink:
    def __init__(self, host: str = "127.0.0.1", port: int = 7777, retry_s: float = 2.0) -> None:
        self.host = host
        self.port = port
        self.retry_s = retry_s
        self.hello: dict | None = None
        self.connected = asyncio.Event()
        self._writer: asyncio.StreamWriter | None = None
        self._handlers: list[FrameHandler] = []

    def on_frame(self, handler: FrameHandler) -> None:
        self._handlers.append(handler)

    async def run(self) -> None:
        """Connect, read frames until disconnect, and retry forever."""
        while True:
            try:
                reader, writer = await asyncio.open_connection(self.host, self.port)
            except OSError:
                await asyncio.sleep(self.retry_s)
                continue
            log.info("connected to face at %s:%d", self.host, self.port)
            self._writer = writer
            self.connected.set()
            try:
                while True:
                    frame = await read_frame(reader)
                    if frame.type == Msg.HELLO:
                        self.hello = frame.json()
                        log.info("face hello: %s", self.hello)
                    for handler in self._handlers:
                        result = handler(frame)
                        if asyncio.iscoroutine(result):
                            await result
            except (asyncio.IncompleteReadError, ConnectionError, ProtocolError) as e:
                log.info("face disconnected: %s", e.__class__.__name__)
            finally:
                self.connected.clear()
                self._writer = None
                self.hello = None
                writer.close()
            await asyncio.sleep(self.retry_s)

    async def send(self, msg_type: int, payload: bytes = b"") -> bool:
        return await self._write(encode(msg_type, payload))

    async def send_json(self, msg_type: int, obj: dict) -> bool:
        return await self._write(encode_json(msg_type, obj))

    async def mood(self, mood: str) -> bool:
        return await self.send_json(Msg.MOOD, {"mood": mood})

    async def state(self, state: str) -> bool:
        return await self.send_json(Msg.STATE, {"state": state})

    async def stop(self) -> bool:
        return await self.send(Msg.STOP)

    async def tts_audio(self, pcm16: bytes, chunk_bytes: int = 4800) -> bool:
        """Send 24 kHz int16 PCM in ~100 ms chunks."""
        for i in range(0, len(pcm16), chunk_bytes):
            if not await self.send(Msg.TTS_AUDIO, pcm16[i:i + chunk_bytes]):
                return False
        return True

    async def _write(self, data: bytes) -> bool:
        writer = self._writer
        if writer is None:
            return False
        try:
            writer.write(data)  # single write call, so frames never interleave
            await writer.drain()
            return True
        except ConnectionError:
            return False
