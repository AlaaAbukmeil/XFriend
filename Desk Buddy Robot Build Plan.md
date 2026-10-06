# Desk Buddy Robot: Build Plan

Oct 6, 2026 · @Alaa

## Overview

The robot is an offline desk companion: a Mac mini runs all the AI and stores every memory, and an iPad connected by one USB cable acts as its face, ears, mouth and eyes. No Wi-Fi, no cloud, no subscriptions.

**The key design rule: the iPad holds nothing important.** All memories, personality and settings live on the Mac. The iPad app is a stateless "face" that only displays eyes, streams audio and plays sound. When the free 7-day signing expires and you reinstall the app, nothing is lost, because there is nothing on the iPad to lose. Memories never need to be "replugged"; the brain simply reconnects to a fresh face.

Backups still matter, so the Mac keeps automatic, timestamped copies of the memory database plus human-readable exports, covered in the backup section below.

## Hardware and software stack

You already own the two expensive parts, so the hardware cost is roughly $0–30 for a cable and a stand. Software is all free and open source, except Xcode, which is free from Apple.

| Layer | Choice | Runs on | Notes |
| --- | --- | --- | --- |
| Brain computer | Mac mini (Apple Silicon) | — | 16GB RAM fits a 7–8B model; 24GB+ fits 12–14B |
| Face, mic, speaker, camera | iPad | — | Any iPad on a recent iPadOS |
| Connection | USB cable + stand | — | Short, good-quality cable; any stand that holds it upright |
| Main language (brain) | Python 3.11+ | Mac | Glue code; models run natively underneath |
| Wake / turn detection | Silero VAD | Mac | Detects start and end of speech |
| Speech to text | mlx-whisper or whisper.cpp | Mac | Uses the Mac GPU |
| LLM | Ollama (or MLX) + a 7–14B instruct model | Mac | Try Qwen, Llama, Gemma families at 4-bit |
| Text to speech | Kokoro | Mac | Multiple voices, speed control |
| Voice effects | pedalboard (Spotify) | Mac | Pitch, reverb, filters for comedic moments |
| Memory storage | SQLite + sqlite-vec | Mac | One file holds all memories |
| Embeddings | nomic-embed-text via Ollama | Mac | Turns memories into searchable vectors |
| USB bridge | libimobiledevice (`iproxy`) | Mac | Forwards a port over the USB cable |
| Face app | Swift + SwiftUI in Xcode | iPad | Free Apple ID; reinstall every 7 days |
|  |  |  |  |

Tool and model names reflect what was current as of mid-2026; check for newer versions before starting.

## System architecture and USB protocol

One USB cable carries everything: audio and camera frames go up to the Mac, and voice audio plus face commands come back down. Only the Mac keeps state.

&#91;embedded content: System architecture · iPad face, USB link, Mac brain\]

**Message format.** Every message is a 1-byte type, a 4-byte length and a payload. Control messages are small JSON objects; audio is raw 16-bit PCM bytes, so nothing is wasted on encoding.

| Direction | Message | Contents |
| --- | --- | --- |
| iPad to Mac | `hello` | App build date and screen size, sent on connect |
| iPad to Mac | `mic_audio` | 20 ms of 16 kHz mono PCM |
| iPad to Mac | `touch` | A tap on the screen (for example, mute toggle) |
| iPad to Mac | `camera_frame` | Low-res JPEG, only when requested |
| Mac to iPad | `tts_audio` | A chunk of the robot's voice (Kokoro outputs 24 kHz) |
| Mac to iPad | `mood` | Expression name, such as `happy` or `sarcastic` |
| Mac to iPad | `state` | `listening`, `thinking` or `speaking` |
| Mac to iPad | `stop` | Flush queued audio immediately (barge-in) |
| Mac to iPad | `request_frame` | Ask the camera for one frame |

If the cable is unplugged or the app restarts, the brain retries the connection every 2 seconds and carries on where it left off.

## Mac brain: voice pipeline and personality

The brain is one long-running Python program on the Mac that listens, thinks, speaks and remembers. Every stage streams into the next so the robot starts talking within about a second.

**Turn flow.** Mic audio arrives from the iPad in 20 ms chunks. Silero VAD decides when you have stopped talking (start with a 500–700 ms silence threshold and tune). Whisper transcribes the utterance. The brain retrieves relevant memories, builds the prompt and streams the LLM reply. Each complete sentence goes straight to Kokoro, and the audio streams back to the iPad while the LLM keeps generating.

**Interruptions (barge-in).** If the VAD hears you speak while the robot is talking, the brain sends a `stop` message to the iPad, cancels the LLM and TTS, and starts listening. The iPad's echo cancellation keeps the robot from hearing itself.

**Personality.** The character lives in a plain text file, `persona.md`, that you edit freely: name, backstory, sense of humor, what it never does. Keep it short and concrete, with a few example lines of how it talks. Bigger models are noticeably funnier, so test two or three and keep the largest one that replies quickly.

**Profanity and dark humor.** Both are allowed. Say so plainly in `persona.md` (for example: swears casually, loves dark and absurd humor, roasts you affectionately) and include a few example lines in that style, because models copy examples more reliably than they follow rules. Some instruct models still clean up their language or add disclaimers; if yours does, try other model families or community fine-tunes with lighter content filtering. Add a `humor` setting to `config.yaml` (such as `clean`, `normal`, `unhinged`) and a voice command like "keep it clean" for when guests are around. List any topics you want off-limits in the persona too, so the dark jokes land as funny rather than hurtful.

**Mood and tone tags.** Instruct the LLM to start each sentence with one tag from a fixed list, such as `[happy]`, `[sarcastic]`, `[sleepy]` or `[excited]`. The brain strips the tag before speaking and uses it three ways: it picks the eye expression on the iPad, it adjusts Kokoro's voice and speed, and for comedy it can route the audio through a pedalboard effect (a dramatic reverb, a chipmunk pitch shift, a radio filter). Keep effects rare so they stay funny.

**Keeping it fast.** Load all models once at startup and keep them in memory. Run the audio receiver, the pipeline and the audio sender as separate async tasks. Measure the time from end of speech to first sound and aim for under 1.2 seconds.

**Framework option.** Pipecat already handles streaming, sentence chunking and interruptions and has a WebSocket transport you can adapt to the USB link. Using it saves weeks; writing the loop yourself teaches more. A good compromise is to start with Pipecat and replace pieces only when you need to.

## iPad face app

The iPad app is small on purpose: one full-screen view, one audio engine and one network connection, with no saved data. Write it in Swift and SwiftUI in Xcode, signed with your free Apple ID.

**Eyes.** Draw the eyes in SwiftUI (two rounded shapes plus eyelids) and animate them by mood: neutral, happy, sarcastic squint, sleepy, surprised, thinking. Add idle life on a timer: random blinks every 3–6 seconds and small glances. Show a distinct "listening" look and a "thinking" look so you always know what state the robot is in.

**Audio in.** Use `AVAudioEngine` with voice processing enabled on the input node. This turns on Apple's echo cancellation and noise suppression. Convert to 16 kHz mono 16-bit PCM and send 20 ms chunks to the Mac.

**Audio out.** Play the TTS audio chunks from the Mac through an `AVAudioPlayerNode` on the same engine, so echo cancellation knows what the robot is saying. On a `stop` message, flush the queue instantly.

**Camera (later phase).** Send a low-resolution frame every few seconds only when the brain asks for one. Start with simple presence detection (someone sat down) before trying full vision.

**Connection.** The app opens a TCP listener on a fixed port (for example 7777) using Apple's Network framework. On the Mac, `iproxy 7777 7777` forwards that port over the USB cable, and the brain connects to `localhost:7777`. The app should accept a new connection at any time, so restarting either side just reconnects.

**Kiosk setup.** Turn off Auto-Lock, enable Guided Access to lock the iPad into the app, and set the app to keep the screen awake while running. The Mac mini's USB port keeps the iPad charged.

## Memory system

All memories live in one SQLite file on the Mac, `memory.db`, organized into four layers that mimic how a friend remembers you. Memories are stored as plain text, so you can swap the LLM later and keep everything.

| Layer | What it holds | Example | When it's written |
| --- | --- | --- | --- |
| Working memory | The current conversation | Last 10–20 turns | Live, in RAM only |
| Episodes | A short summary of each past conversation | "Oct 6: Sam was stressed about a deadline; we joked about coffee" | After each conversation ends |
| Facts | Durable things about you and your life | "Sam plays guitar", "Sam's cat is named Miso" | Extracted after each conversation |
| Relationship | Running jokes, nicknames, shared history | "Calls Sam 'Captain'", "Running joke: the haunted printer" | Extracted, reinforced when reused |

**Database tables.** `episodes` (id, started\_at, ended\_at, summary, mood), `memories` (id, layer, text, importance 1–10, created\_at, last\_used\_at, use\_count, source\_episode\_id, active), `memory_vectors` (a sqlite-vec table keyed by memory id), and `meta` (schema\_version, embedding\_model). Recording the embedding model lets you re-embed everything if you ever change it.

**Writing memories.** When a conversation ends (about 2 minutes of silence), the brain asks the LLM to summarize the episode and extract new facts and relationship moments as JSON, each with an importance score. Before saving, each new memory is compared against existing ones; near-duplicates update the old memory instead of adding a new one, and contradictions ("Sam moved to Denver") mark the old fact inactive rather than deleting it.

**Recalling memories.** At the start of each turn, the brain embeds what you just said and pulls the 5–8 most relevant memories, scored by similarity, importance and recency. It always includes a small pinned set (your name, a top running joke). These go into the prompt under a "Things you remember" heading. Retrieved memories get their `last_used_at` and `use_count` bumped, so jokes that land keep resurfacing.

**Nightly consolidation.** Once a day (for example 3 a.m.), a maintenance job merges duplicates, slowly lowers the importance of memories never used, and rolls old episodes into monthly summaries. It takes a backup before it runs, since it changes the database.

**Your controls.** The robot should handle "what do you remember about me?", "forget that" (marks the memory inactive), and "remember this" (saves with high importance). A small script, `memories.py list`, lets you browse and edit memories from the terminal.

## Saving copies: backups and restore

The robot's whole identity is one folder, `~/BuddyData`, so saving a copy means copying that folder safely. Backups are automatic, timestamped and kept in two formats.

**What gets saved.** `memory.db` (all memories), `persona.md` (personality), `config.yaml` (voice, model, settings) and a `MANIFEST.json` listing the date, schema version, embedding model and memory counts.

**Two formats per snapshot.** A database copy made with SQLite's online backup API, which is safe while the robot is running (never copy the live file with Finder). Plus a readable export, `memories.json` and `memories.md`, so your memories survive even if the database format changes or a file gets corrupted, and so you can read them yourself.

**When snapshots are taken.**

| Trigger | Why |
| --- | --- |
| Every night before consolidation | Protects against a bad merge |
| Before any schema migration or model change | Lets you roll back an upgrade |
| On voice command ("save your memories") | A manual checkpoint before experiments |
| On demand with `backup.py now` | Same, from the terminal |

**Retention.** Keep the last 7 daily snapshots, 4 weekly and 12 monthly, and never delete manual ones. Each snapshot is a few megabytes, so a year of history is tiny.

**Off-machine copies.** Snapshots go to `~/BuddyData/snapshots/`, which Time Machine already covers if you use it. Also copy them to a USB stick or external drive occasionally, since a backup on the same disk doesn't survive a dead disk.

**Restoring.** `restore.py <snapshot-name>` stops the brain, saves the current state as a safety snapshot, copies the chosen snapshot into place, runs any needed migrations and restarts. `restore.py --from-json <file>` rebuilds a fresh database from the readable export and re-embeds everything, which is also how you move the robot to a new Mac.

## The 7-day reinstall routine

Reinstalling the face takes about two minutes and never touches memories, because the brain on the Mac keeps running the whole time. When the app expires, the iPad simply stops showing the face; the robot's mind is unaffected.

1. Leave the iPad plugged into the Mac mini.
2. Open the face app project in Xcode.
3. Select the iPad as the run target and press Run (Cmd+R).
4. Re-enable Guided Access on the iPad if you use it.
5. The app opens, the brain reconnects automatically within a few seconds, and the robot says hello.

**Make the robot remind you.** Embed the build date in the app at compile time and send it to the brain when it connects. The brain then knows when the face expires and can say, in character, "my face expires tomorrow, can you refresh me?" A day-6 reminder means it never goes dark unexpectedly.

**A fun touch.** Have the brain log each reconnect as a tiny memory, so the robot can joke about its "weekly face transplant" without it being a problem.

If you ever want memories on the iPad too (say, to show a "memory book" screen), have the app request them from the brain over the connection rather than storing them. The Mac stays the single source of truth.

## Project folder structure

Keep code and data in separate folders so you can rebuild or update the code without ever touching the robot's memories.

```
~/buddy/                     code (put this in git)
  brain/
    main.py                  starts everything
    pipeline.py              VAD -> STT -> LLM -> TTS
    memory.py                read/write/recall memories
    consolidate.py           nightly maintenance
    face_link.py             USB connection to the iPad
    effects.py               pedalboard voice effects
  tools/
    backup.py                snapshots and retention
    restore.py               restore from snapshot or JSON
    memories.py              browse and edit memories
  face-app/                  Xcode project for the iPad

~/BuddyData/                 the robot's identity (never in git)
  memory.db
  persona.md
  config.yaml
  logs/
  snapshots/
    2026-10-06_0300_nightly/
      memory.db
      memories.json
      memories.md
      MANIFEST.json
```

Use a macOS LaunchAgent to start the brain and `iproxy` automatically at login and restart them if they crash, so the robot is always awake when the Mac is on.

## Build phases and milestones

The build has three phases over roughly 8–12 weeks of evenings. Phase 1 is a complete robot on the Mac alone, using its own speakers and a headset or USB mic, so you can test personality, memory and voice without the iPad in the way.

1. **Phase 1: Mac-only robot (weeks 1–6).** Everything except the face, in five steps that each end with something working:
   1. **Text chat with personality (week 1).** Install Ollama, try 2–3 models, write `persona.md` including the humor style, and chat in the terminal. Done when the replies sound like your character.
   2. **Memory (weeks 2–3).** Build `memory.db`, extraction after conversations and recall per turn. Done when it remembers a fact from yesterday's chat.
   3. **Backups (week 3).** Write `backup.py`, `restore.py` and the JSON export, then practice a full restore. Done when you can wipe the database and bring it back.
   4. **Voice (weeks 4–5).** Add VAD, Whisper and Kokoro using the Mac's speakers and a headset mic (a headset avoids echo until the iPad's echo cancellation arrives). Done when you can talk to it hands-free.
   5. **Speed (week 6).** Add sentence streaming and interruptions, and measure latency. Done when first sound arrives under about 1.2 seconds.
   6. **Optional test face.** A small window on the Mac screen that shows the current mood tag as simple eyes, so you can tune moods before the iPad exists.
2. **Phase 2: iPad face (weeks 7–9).** Build the eye animations, the USB link with `iproxy`, and audio streaming both ways. Since the brain already works, only the face link is new, which makes problems easy to isolate. Done when the robot lives on the iPad and the Mac runs headless.
3. **Phase 3: Polish (weeks 10–12).** Mood tags driving eyes, voice and effects; nightly consolidation; the expiry reminder; LaunchAgent auto-start; optional camera presence detection. Done when it starts itself and you stop thinking about the plumbing.

Start backups at step 3 of phase 1, before memories have any real value to lose.

## Risks and mitigations

The biggest risks are slow replies and an unfunny small model, not hardware; both are solved by testing early.

| Risk | Likely impact | Mitigation |
| --- | --- | --- |
| Replies feel slow | Robot feels dumb | Stream every stage; smaller Whisper model; shorter replies in persona |
| Model isn't funny | Jokes fall flat | Test 2–3 models; add example jokes to persona; use the largest model that stays fast |
| Robot hears itself | Interrupts its own speech | Use iPad voice processing; play audio through the same engine as the mic |
| USB link drops | Face freezes | Auto-reconnect on both sides; LaunchAgent restarts `iproxy` |
| Bad memories pile up | Wrong or repeated facts | Dedupe on write, nightly consolidation, "forget that" command |
| Database corruption | Memories lost | Nightly snapshots plus JSON export plus an off-machine copy |
| Free signing expires | Face goes dark | Day-6 spoken reminder; two-minute reinstall routine |
| Privacy | Always-listening mic | Everything stays on the Mac; add a mute gesture or on-screen mute button on the iPad |
