"""Logging to a fixed, always-reviewable file: ~/XFriendData/logs/brain.log.

Rotates at 5 MB, keeping brain.log.1 .. brain.log.5. The face app writes its own
log next to it (face.log), so one folder holds the whole story.
"""

from __future__ import annotations

import logging
import logging.handlers

from .config import data_dir

FORMAT = "%(asctime)s.%(msecs)03d [%(name)s] %(levelname)s %(message)s"
DATEFMT = "%Y-%m-%d %H:%M:%S"


def setup(tool: str, console_level: int = logging.WARNING) -> None:
    """Call once at program start. `tool` tags every line, e.g. "chat" or "main"."""
    log_dir = data_dir() / "logs"
    log_dir.mkdir(parents=True, exist_ok=True)

    file_handler = logging.handlers.RotatingFileHandler(
        log_dir / "brain.log", maxBytes=5 * 1024 * 1024, backupCount=5, encoding="utf-8",
    )
    file_handler.setFormatter(logging.Formatter(FORMAT.replace("[%(name)s]", f"[{tool}:%(name)s]"), DATEFMT))
    file_handler.setLevel(logging.INFO)

    console = logging.StreamHandler()
    console.setFormatter(logging.Formatter("%(levelname)s %(name)s: %(message)s"))
    console.setLevel(console_level)

    root = logging.getLogger()
    root.setLevel(logging.INFO)
    root.addHandler(file_handler)
    root.addHandler(console)
    # Keep HTTP chatter from the Ollama client out of the file.
    logging.getLogger("httpx").setLevel(logging.WARNING)
    # Kokoro's phonemizer warns on harmless word-count mismatches every few sentences.
    logging.getLogger("phonemizer").setLevel(logging.ERROR)
