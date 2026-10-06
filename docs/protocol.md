# Face ↔ Brain protocol

The face app (macOS in Phase 1, iPad in Phase 2) **listens** on TCP port 7777.
The brain **connects** to `localhost:7777` and retries every 2 s. On the iPad,
`iproxy 7777 7777` makes the iPad's port appear as the Mac's localhost:7777.

## Framing

```
[u8 type][u32 big-endian payload length][payload bytes]
```

- Control payloads are UTF-8 JSON objects.
- Audio payloads are raw little-endian signed 16-bit mono PCM.
- Maximum payload: 4 MiB (anything larger is a protocol error; drop the connection).

## Messages

| Code | Name          | Direction    | Payload |
|------|---------------|--------------|---------|
| 0x01 | hello         | face → brain | `{"build_date": ISO8601, "platform": "macOS"\|"iPadOS", "screen": [w, h]}` |
| 0x02 | mic_audio     | face → brain | 20 ms of 16 kHz PCM (320 samples, 640 bytes) |
| 0x03 | touch         | face → brain | `{"kind": "tap"\|"mute_toggle", "muted": bool?}` |
| 0x04 | camera_frame  | face → brain | JPEG bytes (Phase 2) |
| 0x10 | tts_audio     | brain → face | 24 kHz PCM, any length |
| 0x11 | mood          | brain → face | `{"mood": "neutral"\|"happy"\|"sarcastic"\|"sleepy"\|"surprised"\|"thinking"\|"excited"\|"sad"\|"angry"}` |
| 0x12 | state         | brain → face | `{"state": "idle"\|"listening"\|"thinking"\|"speaking"}` |
| 0x13 | stop          | brain → face | empty; flush queued audio immediately |
| 0x14 | request_frame | brain → face | empty (Phase 2) |

Unknown types must be ignored (not treated as errors) so either side can be
upgraded independently.

## Connection rules

- The face accepts a new connection at any time; a new one replaces the old.
- The face sends `hello` as soon as a connection is accepted.
- The face stops sending `mic_audio` while muted.
