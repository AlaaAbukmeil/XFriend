import numpy as np

from brain.vad import WINDOW, Endpointer


class FakeVAD:
    """Returns scripted probabilities, one per 512-sample window."""

    def __init__(self, probs):
        self.probs = list(probs)

    def reset(self):
        pass

    def prob(self, window):
        return self.probs.pop(0) if self.probs else 0.0


def pcm(windows: int) -> bytes:
    return np.zeros(windows * WINDOW, dtype="<i2").tobytes()


def run(probs, **kw):
    ep = Endpointer(FakeVAD(probs), silence_ms=320, min_speech_ms=96, preroll_ms=64, **kw)
    return ep.feed(pcm(len(probs)))


def test_utterance_produces_start_then_end_with_audio():
    events = run([0.0] * 3 + [0.9] * 10 + [0.0] * 12)
    assert [e.kind for e in events] == ["start", "end"]
    # 2 pre-roll windows + 10 speech + 10 silence windows until end fires
    assert len(events[1].audio) == (2 + 10 + 10) * WINDOW


def test_short_blip_is_ignored():
    events = run([0.9, 0.9] + [0.0] * 15)
    assert events == []


def test_brief_pause_does_not_end_turn():
    events = run([0.9] * 5 + [0.0] * 5 + [0.9] * 5 + [0.0] * 12)
    assert [e.kind for e in events] == ["start", "end"]


def test_chunks_smaller_than_window_accumulate():
    ep = Endpointer(FakeVAD([0.9] * 10 + [0.0] * 12), silence_ms=320, min_speech_ms=96)
    data = pcm(22)
    events = []
    for i in range(0, len(data), 640):  # 20 ms face chunks
        events += ep.feed(data[i:i + 640])
    assert [e.kind for e in events] == ["start", "end"]
