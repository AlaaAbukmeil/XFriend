import asyncio

import pytest

from brain.protocol import MAX_PAYLOAD, FrameDecoder, Msg, ProtocolError, encode, encode_json, read_frame

# Golden bytes, also checked by face-app/Tests/ProtocolTests.swift.
STOP = bytes.fromhex("13 00000000")


def test_golden_mood():
    frame = encode_json(Msg.MOOD, {"mood": "happy"})
    assert frame[:5] == bytes.fromhex("1100000010")
    assert frame[5:] == b'{"mood":"happy"}'


def test_golden_stop():
    assert encode(Msg.STOP) == STOP


def test_decoder_handles_split_and_merged_chunks():
    data = encode_json(Msg.STATE, {"state": "listening"}) + encode(Msg.MIC_AUDIO, b"\x01\x00" * 320) + STOP
    dec = FrameDecoder()
    frames = []
    for i in range(0, len(data), 7):  # deliberately awkward chunk size
        frames += dec.feed(data[i:i + 7])
    assert [f.type for f in frames] == [Msg.STATE, Msg.MIC_AUDIO, Msg.STOP]
    assert frames[0].json() == {"state": "listening"}
    assert len(frames[1].payload) == 640


def test_decoder_rejects_oversized():
    with pytest.raises(ProtocolError):
        FrameDecoder().feed(bytes([0x10]) + (MAX_PAYLOAD + 1).to_bytes(4, "big"))


async def test_read_frame():
    reader = asyncio.StreamReader()
    reader.feed_data(encode_json(Msg.HELLO, {"platform": "macOS"}))
    reader.feed_eof()
    frame = await read_frame(reader)
    assert frame.type == Msg.HELLO and frame.json() == {"platform": "macOS"}
