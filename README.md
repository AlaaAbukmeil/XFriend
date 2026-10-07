# XFriend

An offline desk companion robot. A **Mac mini** runs the robot's brain: speech recognition, the LLM, text to speech and memory. A **Swift face app** shows its eyes, listens through the mic and plays its voice. Nothing goes to the cloud, and there are no subscriptions.

The face app holds no state. All memories, personality and settings live on the Mac in `~/XFriendData`, so the face can be reinstalled or restarted at any time without losing anything.

The full design is in [Desk Buddy Robot Build Plan.md](Desk%20Buddy%20Robot%20Build%20Plan.md).

## How it fits together

```
 Face app (Swift)                              Brain (Python, on the Mac)
 ┌───────────────────────┐   TCP :7777         ┌───────────────────────────────┐
 │ eyes · mic · speaker  │ ◄─────────────────► │ VAD → Whisper → LLM → Kokoro  │
 │ listens on 127.0.0.1  │  mic audio, touch → │ memory (SQLite) · persona     │
 │                       │ ← voice, mood, state│ connects, retries every 2 s   │
 └───────────────────────┘                     └───────────────────────────────┘
```

The face **listens** on port 7777 and the brain **connects** to `localhost:7777`. Both sides use the same wire format, defined in [docs/protocol.md](docs/protocol.md): a 1-byte type, a 4-byte length, then the payload.

Development happens in two phases:

| Phase | Face runs on | How the brain reaches it |
|---|---|---|
| **1: Mac only** (current) | A macOS window on the Mac mini | Directly, on localhost:7777 |
| **2: iPad** | An iPad on a stand, plugged in by USB | `iproxy 7777 7777` forwards the port over USB |

The brain is identical in both phases. Only the face moves.

## Repo layout

```
brain/                  Python brain
  main.py               the robot: loads all models once, then talks through the face
  pipeline.py           VAD -> Whisper -> LLM -> Kokoro, streaming, barge-in, latency log
  vad.py                Silero VAD (ONNX) + end-of-turn endpointer
  stt.py                mlx-whisper speech to text
  tts.py                Kokoro text to speech, speed by mood
  protocol.py           frame encode/decode (mirrors face-app/Shared/Protocol.swift)
  face_link.py          TCP client to the face, auto-reconnect
  llm.py                Ollama streaming, mood tags, sentence splitting
  config.py             loads ~/XFriendData (persona.md, config.yaml)
  logs.py               file logging to ~/XFriendData/logs/brain.log
  defaults/             starter persona.md and config.yaml, copied on first run
tools/
  chat.py               terminal text chat with the robot
  fake_brain.py         drives the face without AI (moods, states, test tone, echo)
tests/                  pytest suite
face-app/               Swift face app
  project.yml           XcodeGen spec (the .xcodeproj is generated, not committed)
  Shared/               code shared by macOS and (later) iPadOS
  macOS/                macOS app entry point
  Resources/            asset catalog (app icon)
  Tests/                XCTest protocol tests (same golden bytes as the Python tests)
  tools/make_icon.swift renders the app icon
docs/protocol.md        the wire protocol, the source of truth for both sides
models/                 downloaded model files (git-ignored, see Setup)
```

The robot's identity lives **outside** the repo and is never committed:

```
~/XFriendData/
  persona.md            who the robot is: edit freely
  config.yaml           model, humor level, user name, face port
  logs/                 face.log and brain.log
  snapshots/            backups (coming in step 1.6)
```

Set `XFRIEND_DATA=/some/path` to use a different folder. Both the brain and the Mac face app honor it.

## Setup

Requirements: an Apple Silicon Mac, Xcode, and Homebrew.

```sh
brew install uv ollama xcodegen
brew services start ollama
ollama pull qwen3:8b && ollama pull nomic-embed-text

uv sync                     # installs Python 3.12 + dependencies into .venv

# Voice model files (about 400 MB) go in models/
mkdir -p models && cd models
curl -LO https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx
curl -LO https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx
curl -LO https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin
cd ..
# Whisper (about 1.6 GB) downloads itself from Hugging Face on first run.
```

Build the face app:

```sh
cd face-app
xcodegen generate
xcodebuild -project XFriend.xcodeproj -scheme XFriend-macOS -derivedDataPath build build
open build/Build/Products/Debug/XFriend.app
```

You can also run `xcodegen generate` and then open `XFriend.xcodeproj` in Xcode and press Cmd+R. Rerun `xcodegen generate` after adding or removing Swift files.

## Running things

| Command | What it does |
|---|---|
| `uv run python -m brain.main` | **The robot.** Talk to it hands-free through the face app |
| `uv run python -m tools.chat` | Text chat in the terminal |
| `uv run python -m tools.chat --face` | Text chat, with the face app's eyes following the mood |
| `uv run python -m tools.chat --compare qwen3:8b,llama3.1:8b` | Every message goes to several models side by side |
| `uv run python -m tools.fake_brain` | Cycles every state and mood on the face |
| `uv run python -m tools.fake_brain --tone` | Plays a 1 s tone through the face (checks playback) |
| `uv run python -m tools.fake_brain --stop` | Starts a long tone, then cuts it off (checks barge-in) |
| `uv run python -m tools.fake_brain --echo` | Records 3 s of mic audio and plays it back (needs a mic) |
| `uv run python -m tools.sim_face --port 7799` | Pretend face that "speaks" test lines to the brain and reports latency. Run the brain with `XFRIEND_FACE_PORT=7799`. Add `--barge-in` to test interruptions |

Chat commands: `/humor clean|normal|unhinged`, `/reset`, `/quit`.

Voice commands (said to the robot): "keep it clean" / "guests are here" → clean humor; "back to normal"; "no filter" / "go unhinged".

Voice and turn-taking settings (voice, speed, Whisper model, barge-in, silence threshold) live in `~/XFriendData/config.yaml` under `voice:` and `vad:`. Every turn logs its latency to `brain.log`, for example `latency stt=0.31s llm=0.72s first_audio=0.95s`.

In the face window, press **d** to show the debug overlay and **m** (or click) to mute.

## Logs

Everything is in `~/XFriendData/logs/`:

- `face.log`: face app startup, audio devices, connections, every control message received, crash reasons. Rotates at 5 MB.
- `brain.log`: connections, the face's hello, every chat turn with its latency, errors. Rotates at 5 MB, keeping 5 old files.

```sh
tail -f ~/XFriendData/logs/face.log ~/XFriendData/logs/brain.log
```

Crash reports from macOS are in `~/Library/Logs/DiagnosticReports/XFriend-*.ips`.

## Tests

```sh
uv run pytest                                                  # Python
cd face-app && xcodebuild -project XFriend.xcodeproj \
  -scheme XFriend-macOS -derivedDataPath build test          # Swift
```

Both suites check the same golden protocol bytes, so the two sides can't drift apart.

## Status

Phase 1 progress:

- [x] **1.0 Setup**: toolchain, models, `~/XFriendData`
- [x] **1.1 Text chat with personality**: persona, mood tags, humor levels, model comparison
- [x] **1.2 Face app on macOS**: eyes with moods and states, blinks and glances, TCP link, auto-reconnect, logs, icon
- [x] **1.3 Audio through the face**: playback and mic capture, auto-recovery when devices change
- [ ] **1.4 Voice pipeline**: built and working end to end with barge-in; first sound is 1.3–2.0 s after you stop talking (target 1.2 s)
- [ ] **1.5 Memory**: SQLite + sqlite-vec, recall per turn, extraction after conversations
- [ ] **1.6 Backups**: snapshots, JSON export, restore
- [ ] **1.7 Mood polish**: mood drives voice and effects, nightly consolidation

Phase 2 (iPad target, USB link, expiry reminder, camera, always-on setup) starts once Phase 1 is done.

### Known gotchas

- **The Mac mini has no built-in microphone.** The face app detects this and runs playback-only. Use a headset or USB mic for voice. The face picks up a newly connected device by itself, with no restart.
- **Bluetooth headsets** (tested with Sony XM5) reject Apple's echo cancellation, so the face falls back to the plain mic; `face.log` says `NO echo cancel`. That's fine with headphones. If you use speakers with such a mic, set `voice.barge_in: false`, or the robot may interrupt itself.
- The first LLM reply after a cold start takes several seconds while the model loads. Later replies start in about 1 s.
- In zsh, `log` is a shell builtin. Use `/usr/bin/log` to query the macOS system log.
