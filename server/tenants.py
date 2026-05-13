"""Tenant config loader for Bloom Dictate."""
from __future__ import annotations

from pathlib import Path
from typing import List

import yaml
from pydantic import BaseModel, Field


class PostCorrectionConfig(BaseModel):
    enabled: bool = True
    model: str = "qwen2.5:14b"
    system_prompt: str = ""


class PromptModeConfig(BaseModel):
    enabled: bool = False
    model: str = "qwen2.5:14b"
    system_prompt: str = ""


class TenantConfig(BaseModel):
    tenant_id: str
    display_name: str = ""
    language: str = "en"
    model: str = "mlx-community/whisper-large-v3-turbo"
    keep_audio: bool = False
    terms: List[str] = Field(default_factory=list)
    phrases: List[str] = Field(default_factory=list)
    post_correction: PostCorrectionConfig = Field(default_factory=PostCorrectionConfig)
    prompt_mode: PromptModeConfig = Field(default_factory=PromptModeConfig)


def load_tenant(path: Path) -> TenantConfig:
    data = yaml.safe_load(path.read_text())
    return TenantConfig(**data)


def build_initial_prompt(tenant: TenantConfig, max_chars: int = 800) -> str:
    """Build whisper initial_prompt string from tenant glossary.

    Whisper's initial_prompt window is ~200 tokens; ~800 chars is a safe heuristic.
    Prioritise terms over phrases when truncating.
    """
    parts = []
    if tenant.terms:
        parts.append(", ".join(tenant.terms))
    if tenant.phrases:
        parts.append(", ".join(tenant.phrases))
    full = "Glossary: " + "; ".join(parts) + "."
    if len(full) > max_chars:
        full = full[: max_chars - 3] + "..."
    return full
