"""Relationship AI Keyboard — FastAPI backend.

Run:  uvicorn app.main:app --host 0.0.0.0 --port 8000
Env:  GEMINI_API_KEY (server only), APP_API_KEY (shared secret the iOS app sends
      as X-API-Key), GEMINI_MODEL (optional, default gemini-2.0-flash)
Deploy behind HTTPS (any reverse proxy / platform TLS). This service stores
nothing: requests are processed in memory and not logged with message content.
"""
from __future__ import annotations

import hmac
import os

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field

from . import conversations as conv
from . import gemini

app = FastAPI(title="Relationship AI Keyboard API", version="1.0.0")


# --- Auth ---------------------------------------------------------------------
async def require_api_key(x_api_key: str = Header(default="")) -> None:
    expected = os.environ.get("APP_API_KEY", "")
    if not expected:
        raise HTTPException(500, "APP_API_KEY is not configured on the server")
    if not hmac.compare_digest(x_api_key, expected):
        raise HTTPException(401, "Invalid or missing X-API-Key")


# --- Schemas ------------------------------------------------------------------
class MessageIn(BaseModel):
    text: str = Field(min_length=1, max_length=conv.MAX_MESSAGE_CHARS)
    sender: str = Field(pattern="^(me|other|unknown)$")
    confidence: float = Field(default=1.0, ge=0.0, le=1.0)


class ChatRequest(BaseModel):
    messages: list[MessageIn] = Field(min_length=1, max_length=conv.MAX_MESSAGES)
    language_hint: str | None = None


class AnalyzeResponse(BaseModel):
    language: str
    tone: str
    topic: str
    latest_incoming_text: str | None
    summary: str


class GenerateResponse(BaseModel):
    suggestions: list[str]
    language: str
    based_on_message_count: int


def _prepare(req: ChatRequest) -> list[conv.Message]:
    messages = conv.clean_messages([conv.Message(text=m.text, sender=m.sender, confidence=m.confidence) for m in req.messages])
    if not messages:
        # Empty context must never produce suggestions.
        raise HTTPException(422, "No usable messages after cleaning — nothing to base replies on")
    return messages


# --- Routes -------------------------------------------------------------------
@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "gemini_configured": bool(os.environ.get("GEMINI_API_KEY"))}


@app.post("/analyze-chat", response_model=AnalyzeResponse, dependencies=[Depends(require_api_key)])
async def analyze_chat(req: ChatRequest) -> AnalyzeResponse:
    messages = _prepare(req)
    language = conv.detect_language(messages)
    latest = conv.latest_incoming(messages)
    try:
        result = await gemini.analyze(messages, language)
    except gemini.GeminiNotConfigured:
        # Analysis can degrade honestly (local labels only); generation cannot.
        result = {"tone": conv.heuristic_tone(messages), "topic": "", "summary": "Model unavailable — local analysis only."}
    except gemini.GeminiResponseError as exc:
        raise HTTPException(502, str(exc)) from exc
    return AnalyzeResponse(language=language, tone=result["tone"], topic=result["topic"],
                           latest_incoming_text=latest.text if latest else None, summary=result["summary"])


@app.post("/generate-replies", response_model=GenerateResponse, dependencies=[Depends(require_api_key)])
async def generate_replies(req: ChatRequest) -> GenerateResponse:
    messages = _prepare(req)
    language = conv.detect_language(messages)
    try:
        suggestions = await gemini.generate_replies(messages, language)
    except gemini.GeminiNotConfigured as exc:
        raise HTTPException(503, str(exc)) from exc
    except gemini.GeminiResponseError as exc:
        raise HTTPException(502, str(exc)) from exc
    return GenerateResponse(suggestions=suggestions, language=language, based_on_message_count=len(messages))
