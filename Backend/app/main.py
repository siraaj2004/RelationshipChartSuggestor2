"""Relationship AI Keyboard — FastAPI backend.

Run:  uvicorn app.main:app --host 0.0.0.0 --port 8000
Env:  GEMINI_API_KEY (server only), APP_API_KEY (shared secret the iOS app sends
      as X-API-Key), GEMINI_MODEL (optional, default gemini-3.5-flash-lite)
Deploy behind HTTPS (any reverse proxy / platform TLS). Requests are not
logged with message content. The only state kept is the broadcast-scan relay
(/scan-ingest → /scan-latest): extracted text + suggestions held in memory,
keyed by a hash of the app key, auto-expiring after 2 hours, never on disk.
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
async def require_api_key(x_api_key: str = Header(default="")) -> str:
    expected = os.environ.get("APP_API_KEY", "")
    if not expected:
        raise HTTPException(500, "APP_API_KEY is not configured on the server")
    if not hmac.compare_digest(x_api_key, expected):
        raise HTTPException(401, "Invalid or missing X-API-Key")
    return x_api_key


# --- Schemas ------------------------------------------------------------------
class MessageIn(BaseModel):
    text: str = Field(min_length=1, max_length=conv.MAX_MESSAGE_CHARS)
    sender: str = Field(pattern="^(me|other|unknown)$")
    confidence: float = Field(default=1.0, ge=0.0, le=1.0)


class SuggestionContext(BaseModel):
    """Hints the user provides about their own situation (never treated as
    conversation history — see gemini.generate_replies)."""
    days_chatting: int | None = Field(default=None, ge=0, le=3650)
    goal: str | None = Field(default=None, max_length=40)
    tone: str | None = Field(default=None, max_length=20)


class ChatRequest(BaseModel):
    messages: list[MessageIn] = Field(min_length=1, max_length=conv.MAX_MESSAGES)
    language_hint: str | None = None
    context: SuggestionContext | None = None


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


# --- Broadcast-scan relay -------------------------------------------------------
# Why this exists: on free-signed installs (Sideloadly + free Apple ID), iOS
# blocks the App Group channel the broadcast extension would normally use to
# hand scanned text to the app/keyboard. The extension therefore uploads the
# extracted text here during a user-started broadcast, and the app/keyboard
# fetch it back. Entries are keyed by a hash of the caller's app key, kept in
# memory only, and expire after SCAN_TTL_SECONDS. Nothing is written to disk.
import hashlib
import time

SCAN_TTL_SECONDS = 2 * 3600
_scan_store: dict[str, dict] = {}


def _scan_slot_key(api_key: str) -> str:
    return hashlib.sha256(api_key.encode()).hexdigest()


def _scan_get(api_key: str) -> dict | None:
    entry = _scan_store.get(_scan_slot_key(api_key))
    if entry is None:
        return None
    if time.time() - entry["updated_at"] > SCAN_TTL_SECONDS:
        _scan_store.pop(_scan_slot_key(api_key), None)
        return None
    return entry


class ScanLatestResponse(BaseModel):
    messages: list[MessageIn]
    language: str
    suggestions: list[str]
    based_on_message_count: int
    updated_at: float


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
        suggestions = await gemini.generate_replies(messages, language, req.context)
    except gemini.GeminiNotConfigured as exc:
        raise HTTPException(503, str(exc)) from exc
    except gemini.GeminiResponseError as exc:
        raise HTTPException(502, str(exc)) from exc
    return GenerateResponse(suggestions=suggestions, language=language, based_on_message_count=len(messages))


@app.post("/scan-ingest", response_model=GenerateResponse)
async def scan_ingest(req: ChatRequest, api_key: str = Depends(require_api_key)) -> GenerateResponse:
    """Broadcast extension uploads extracted chat text during a user-started
    scan. Suggestions are generated immediately and stored (see relay note
    above) so the app and keyboard can fetch them via /scan-latest."""
    messages = _prepare(req)
    language = conv.detect_language(messages)
    try:
        suggestions = await gemini.generate_replies(messages, language, req.context)
    except gemini.GeminiNotConfigured as exc:
        raise HTTPException(503, str(exc)) from exc
    except gemini.GeminiResponseError as exc:
        raise HTTPException(502, str(exc)) from exc
    _scan_store[_scan_slot_key(api_key)] = {
        "messages": [{"text": m.text, "sender": m.sender, "confidence": m.confidence} for m in messages],
        "language": language,
        "suggestions": suggestions,
        "based_on_message_count": len(messages),
        "updated_at": time.time(),
    }
    return GenerateResponse(suggestions=suggestions, language=language, based_on_message_count=len(messages))


@app.get("/scan-latest", response_model=ScanLatestResponse)
async def scan_latest(api_key: str = Depends(require_api_key)) -> ScanLatestResponse:
    entry = _scan_get(api_key)
    if entry is None:
        raise HTTPException(404, "No scan results stored (none received yet, or expired)")
    return ScanLatestResponse(**entry)


@app.delete("/scan-latest")
async def scan_delete(api_key: str = Depends(require_api_key)) -> dict:
    _scan_store.pop(_scan_slot_key(api_key), None)
    return {"deleted": True}
