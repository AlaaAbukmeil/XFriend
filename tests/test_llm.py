from brain.llm import SentenceStream, split_tagged


def test_split_tagged_multiple_tags():
    out = split_tagged("[happy] Hi there! [sarcastic] Great to see you.", "neutral")
    assert [(s.mood, s.text) for s in out] == [("happy", "Hi there!"), ("sarcastic", "Great to see you.")]


def test_unknown_tag_keeps_current_mood():
    out = split_tagged("[grumpy] Whatever.", "sleepy")
    assert [(s.mood, s.text) for s in out] == [("sleepy", "Whatever.")]


def test_stream_emits_sentences_as_they_complete():
    stream = SentenceStream()
    tokens = ["[hap", "py] Hel", "lo! ", "[thinking] Hmm", ", let me", " think. And", " more"]
    got = []
    for t in tokens:
        got += [(s.mood, s.text) for s in stream.feed(t)]
    assert got == [("happy", "Hello!"), ("thinking", "Hmm, let me think.")]
    assert [(s.mood, s.text) for s in stream.flush()] == [("thinking", "And more")]


def test_mood_carries_over_untagged_sentences():
    stream = SentenceStream()
    got = stream.feed("[sad] Oh no. That sucks. ") + stream.flush()
    assert [(s.mood, s.text) for s in got] == [("sad", "Oh no."), ("sad", "That sucks.")]
