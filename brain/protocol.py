"""Face <-> brain wire protocol. See docs/protocol.md.

Frame: [u8 type][u32 big-endian length][payload]
"""

from __future__ import annotations

import asyncio
import json
import struct
from dataclasses import dataclass
from enum import IntEnum

HEADER = struct.Struct(">BI")
MAX_PAYLOAD = 4 * 1024 * 1024

MIC_SAMPLE_RATE = 16_000
TTS_SAMPLE_RATE = 24_000


class Msg(IntEnum):
    HELLO = 0x01
    MIC_AUDIO = 0x02
    TOUCH = 0x03
    CAMERA_FRAME = 0x04
    TTS_AUDIO = 0x10
    MOOD = 0x11
    STATE = 0x12
    STOP = 0x13
    REQUEST_FRAME = 0x14


JSON_TYPES = {Msg.HELLO, Msg.TOUCH, Msg.MOOD, Msg.STATE}


class ProtocolError(Exception):
    pass


@dataclass
class Frame:
    type: int
    payload: bytes

    def json(self) -> dict:
        return json.loads(self.payload.decode("utf-8")) if self.payload else {}


def encode(msg_type: int, payload: bytes = b"") -> bytes:
    if len(payload) > MAX_PAYLOAD:
        raise ProtocolError(f"payload too large: {len(payload)}")
    return HEADER.pack(msg_type, len(payload)) + payload


def encode_json(msg_type: int, obj: dict) -> bytes:
    return encode(msg_type, json.dumps(obj, separators=(",", ":")).encode("utf-8"))


async def read_frame(reader: asyncio.StreamReader) -> Frame:
    header = await reader.readexactly(HEADER.size)
    msg_type, length = HEADER.unpack(header)
    if length > MAX_PAYLOAD:
        raise ProtocolError(f"payload too large: {length}")
    payload = await reader.readexactly(length) if length else b""
    return Frame(msg_type, payload)


class FrameDecoder:
    """Incremental decoder for byte streams that arrive in arbitrary chunks."""

    def __init__(self) -> None:
        self._buf = bytearray()

    def feed(self, data: bytes) -> list[Frame]:
        self._buf.extend(data)
        frames = []
        while len(self._buf) >= HEADER.size:
            msg_type, length = HEADER.unpack_from(self._buf)
            if length > MAX_PAYLOAD:
                raise ProtocolError(f"payload too large: {length}")
            end = HEADER.size + length
            if len(self._buf) < end:
                break
            frames.append(Frame(msg_type, bytes(self._buf[HEADER.size:end])))
            del self._buf[:end]
        return frames
