"""Loads the robot's identity from ~/BuddyData (override with $BUDDY_DATA).

On first run, starter persona.md and config.yaml are copied in from brain/defaults/.
"""

from __future__ import annotations

import os
import shutil
from dataclasses import dataclass, field
from pathlib import Path

import yaml

DEFAULTS_DIR = Path(__file__).parent / "defaults"


def data_dir() -> Path:
    return Path(os.environ.get("BUDDY_DATA", Path.home() / "BuddyData")).expanduser()


@dataclass
class Config:
    data: Path
    persona: str
    model: str = "qwen3:8b"
    embed_model: str = "nomic-embed-text"
    humor: str = "normal"
    user_name: str = "friend"
    face_host: str = "127.0.0.1"
    face_port: int = 7777
    raw: dict = field(default_factory=dict)

    @property
    def persona_path(self) -> Path:
        return self.data / "persona.md"

    @property
    def config_path(self) -> Path:
        return self.data / "config.yaml"


def ensure_data_dir(data: Path) -> None:
    for sub in ("logs", "snapshots"):
        (data / sub).mkdir(parents=True, exist_ok=True)
    for name in ("persona.md", "config.yaml"):
        if not (data / name).exists():
            shutil.copy(DEFAULTS_DIR / name, data / name)


def load() -> Config:
    data = data_dir()
    ensure_data_dir(data)
    raw = yaml.safe_load((data / "config.yaml").read_text()) or {}
    face = raw.get("face", {})
    return Config(
        data=data,
        persona=(data / "persona.md").read_text(),
        model=raw.get("model", "qwen3:8b"),
        embed_model=raw.get("embed_model", "nomic-embed-text"),
        humor=raw.get("humor", "normal"),
        user_name=raw.get("user_name", "friend"),
        face_host=face.get("host", "127.0.0.1"),
        face_port=int(face.get("port", 7777)),
        raw=raw,
    )
