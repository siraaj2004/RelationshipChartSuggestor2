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
from . import workflow as wf

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
    preferred_language: str | None = Field(
        default=None,
        pattern="^(auto|english|roman_urdu|roman_telugu|mixed_telugu_english|mixed_urdu_english)$")


def _language(req: ChatRequest, messages: list[conv.Message]) -> str:
    """Language for generation: the user's explicit chat-language
    preference wins over detection (2026-10-27). This is the most
    reliable fix when detection keeps misreading short/chatty
    conversations — the user sets it once in Your inputs, and
    suggestions always use it. Otherwise detect from the messages."""
    pref = (req.context.preferred_language if req.context else None) or "auto"
    if pref != "auto":
        return pref
    return conv.detect_reply_language(messages)


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


class AskRequest(ChatRequest):
    """A question about the scanned conversation, e.g. 'what does she
    mean by the last message?' or 'how should I reply to this?'"""
    question: str = Field(min_length=1, max_length=500)


class AskResponse(BaseModel):
    answer: str
    suggestions: list[str]
    language: str
    based_on_message_count: int


class GuideResponse(BaseModel):
    """Guide mode: send/wait decision + reason + action + 3 drafts.
    Drafts are NEVER sent by the server — the app shows them for the
    user to review, and only SEND drafts are published to the keyboard.
    WAIT drafts stay in the app as 'for later' ideas."""
    decision: str
    reason: str
    action: str
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


class ScanStoreRequest(BaseModel):
    """The app publishes results it already generated (e.g. from screenshot
    import) so the keyboard can fetch the same suggestions from the relay."""
    messages: list[MessageIn]
    language: str = Field(pattern="^(english|roman_urdu|roman_telugu|mixed|unknown)$")
    suggestions: list[str] = Field(min_length=3, max_length=3)


def _prepare(req: ChatRequest) -> list[conv.Message]:
    messages = conv.clean_messages([conv.Message(text=m.text, sender=m.sender, confidence=m.confidence) for m in req.messages])
    if not messages:
        # Empty context must never produce suggestions.
        raise HTTPException(422, "No usable messages after cleaning — nothing to base replies on")
    # Recent-message accuracy (2026-10-27): a long chat's older messages
    # dilute the latest topic and produce replies to the wrong message.
    # Keep only the most recent 25 messages for analysis/generation;
    # the last message is always kept, and it is the reply target.
    return messages[-25:]


# --- Routes -------------------------------------------------------------------
@app.get("/health")
async def health() -> dict:
    return {"status": "ok", "gemini_configured": bool(os.environ.get("GEMINI_API_KEY"))}


@app.post("/analyze-chat", response_model=AnalyzeResponse, dependencies=[Depends(require_api_key)])
async def analyze_chat(req: ChatRequest) -> AnalyzeResponse:
    messages = _prepare(req)
    language = _language(req, messages)
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
    language = _language(req, messages)
    try:
        suggestions = await gemini.generate_replies(messages, language, req.context)
    except gemini.GeminiNotConfigured as exc:
        raise HTTPException(503, str(exc)) from exc
    except gemini.GeminiResponseError as exc:
        raise HTTPException(502, str(exc)) from exc
    return GenerateResponse(suggestions=suggestions, language=language, based_on_message_count=len(messages))


@app.post("/ask-chat", response_model=AskResponse, dependencies=[Depends(require_api_key)])
async def ask_chat(req: AskRequest) -> AskResponse:
    messages = _prepare(req)
    language = _language(req, messages)
    try:
        result = await gemini.ask_about_chat(messages, language, req.question.strip())
    except gemini.GeminiNotConfigured as exc:
        raise HTTPException(503, str(exc)) from exc
    except gemini.GeminiResponseError as exc:
        raise HTTPException(502, str(exc)) from exc
    return AskResponse(answer=result["answer"], suggestions=result["suggestions"],
                       language=language, based_on_message_count=len(messages))


@app.post("/guide-chat", response_model=GuideResponse, dependencies=[Depends(require_api_key)])
async def guide_chat(req: ChatRequest) -> GuideResponse:
    messages = _prepare(req)
    language = _language(req, messages)
    try:
        result = await gemini.guide_chat(messages, language, req.context)
    except gemini.GeminiNotConfigured as exc:
        raise HTTPException(503, str(exc)) from exc
    except gemini.GeminiResponseError as exc:
        raise HTTPException(502, str(exc)) from exc
    return GuideResponse(decision=result["decision"], reason=result["reason"],
                         action=result["action"], suggestions=result["suggestions"],
                         language=language, based_on_message_count=len(messages))


@app.post("/scan-ingest", response_model=GenerateResponse)
async def scan_ingest(req: ChatRequest, api_key: str = Depends(require_api_key)) -> GenerateResponse:
    """Broadcast extension uploads extracted chat text during a user-started
    scan. Suggestions are generated immediately and stored (see relay note
    above) so the app and keyboard can fetch them via /scan-latest."""
    messages = _prepare(req)
    language = conv.detect_reply_language(messages)
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


@app.post("/scan-store")
async def scan_store(req: ScanStoreRequest, api_key: str = Depends(require_api_key)) -> dict:
    messages = [{"text": m.text, "sender": m.sender, "confidence": m.confidence} for m in req.messages]
    if not messages:
        raise HTTPException(422, "messages must not be empty")
    _scan_store[_scan_slot_key(api_key)] = {
        "messages": messages,
        "language": req.language,
        "suggestions": [s.strip() for s in req.suggestions],
        "based_on_message_count": len(messages),
        "updated_at": time.time(),
    }
    return {"stored": True}


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


# --- Approval-only relationship workflow --------------------------------------
# Manual contacts only: no discovery, search, scraping or Instagram
# automation exists in this API. Every route below either stores what the
# user adds, prepares a DRAFT for the user's approval (never sends), records
# an action the user confirms they took themselves, or reminds the USER.
# See app/workflow.py for the rules enforced in code.

class ContactIn(BaseModel):
    username: str = Field(min_length=1, max_length=64)
    how_known: str  # known_personally | mutual_follow | contacted_me_first
    adult_confirmed: bool = False
    shared_interest: str = Field(default="", max_length=200)
    community_volunteered: str = Field(default="", max_length=80)
    community_permission_to_record: bool = False


class DraftIn(BaseModel):
    language: str = Field(default="english", pattern="^(english|roman_urdu|roman_telugu)$")
    now: float | None = None


class RecordSentIn(BaseModel):
    sent_at: float | None = None


class ImportIn(BaseModel):
    messages: list[MessageIn] = Field(min_length=1, max_length=conv.MAX_MESSAGES)


class EvaluateIn(BaseModel):
    family_views_aligned: bool | None = None
    family_perspective_summary: str = Field(default="", max_length=400)
    serious_relationship_aligned: bool | None = None
    marriage_expectations_aligned: bool | None = None
    independence_aligned: bool | None = None


def _contact_or_404(api_key: str, contact_id: str) -> dict:
    contact = wf.get_contact(api_key, contact_id)
    if contact is None:
        raise HTTPException(404, "Contact not found")
    return contact


def _wf_call(fn, *args, **kwargs):
    try:
        return fn(*args, **kwargs)
    except wf.WorkflowError as exc:
        raise HTTPException(422, str(exc)) from exc


@app.post("/workflow/contacts", dependencies=[Depends(require_api_key)])
async def wf_create_contact(req: ContactIn, api_key: str = Depends(require_api_key)) -> dict:
    return _wf_call(wf.create_contact, api_key, username=req.username, how_known=req.how_known,
                    adult_confirmed=req.adult_confirmed, shared_interest=req.shared_interest,
                    community_volunteered=req.community_volunteered,
                    community_permission_to_record=req.community_permission_to_record)


@app.get("/workflow/contacts", dependencies=[Depends(require_api_key)])
async def wf_list_contacts(api_key: str = Depends(require_api_key)) -> dict:
    return {"contacts": wf.list_contacts(api_key)}


@app.delete("/workflow/contacts/{contact_id}", dependencies=[Depends(require_api_key)])
async def wf_delete_contact(contact_id: str, api_key: str = Depends(require_api_key)) -> dict:
    if not wf.delete_contact(api_key, contact_id):
        raise HTTPException(404, "Contact not found")
    return {"deleted": True}


@app.post("/workflow/contacts/{contact_id}/intro-draft", dependencies=[Depends(require_api_key)])
async def wf_intro_draft(contact_id: str, req: DraftIn, api_key: str = Depends(require_api_key)) -> dict:
    return _wf_call(wf.intro_draft, _contact_or_404(api_key, contact_id), req.language)


@app.post("/workflow/contacts/{contact_id}/record-intro-sent", dependencies=[Depends(require_api_key)])
async def wf_record_intro(contact_id: str, req: RecordSentIn, api_key: str = Depends(require_api_key)) -> dict:
    return _wf_call(wf.record_intro_sent, _contact_or_404(api_key, contact_id), req.sent_at)


@app.post("/workflow/contacts/{contact_id}/followup-draft", dependencies=[Depends(require_api_key)])
async def wf_followup_draft(contact_id: str, req: DraftIn, api_key: str = Depends(require_api_key)) -> dict:
    return _wf_call(wf.followup_draft, _contact_or_404(api_key, contact_id), req.language, req.now)


@app.post("/workflow/contacts/{contact_id}/record-followup-sent", dependencies=[Depends(require_api_key)])
async def wf_record_followup(contact_id: str, req: RecordSentIn, api_key: str = Depends(require_api_key)) -> dict:
    return _wf_call(wf.record_followup_sent, _contact_or_404(api_key, contact_id), req.sent_at)


@app.post("/workflow/contacts/{contact_id}/record-declined", dependencies=[Depends(require_api_key)])
async def wf_record_declined(contact_id: str, api_key: str = Depends(require_api_key)) -> dict:
    return _wf_call(wf.record_declined, _contact_or_404(api_key, contact_id))


@app.get("/workflow/reminders", dependencies=[Depends(require_api_key)])
async def wf_reminders(now: float | None = None, api_key: str = Depends(require_api_key)) -> dict:
    """Reminders for the USER only — nothing is sent to any contact."""
    return {"reminders": wf.due_reminders(api_key, now)}


@app.post("/workflow/contacts/{contact_id}/import-chat", dependencies=[Depends(require_api_key)])
async def wf_import_chat(contact_id: str, req: ImportIn, api_key: str = Depends(require_api_key)) -> dict:
    contact = _contact_or_404(api_key, contact_id)
    raw = [conv.Message(text=m.text, sender=m.sender, confidence=m.confidence) for m in req.messages]
    return _wf_call(wf.import_chat, api_key, contact, raw)


@app.get("/workflow/contacts/{contact_id}/family-questions", dependencies=[Depends(require_api_key)])
async def wf_family_questions(contact_id: str, api_key: str = Depends(require_api_key)) -> dict:
    return _wf_call(wf.family_questions, _contact_or_404(api_key, contact_id))


@app.post("/workflow/contacts/{contact_id}/evaluate", dependencies=[Depends(require_api_key)])
async def wf_evaluate(contact_id: str, req: EvaluateIn, api_key: str = Depends(require_api_key)) -> dict:
    contact = _contact_or_404(api_key, contact_id)
    return _wf_call(wf.evaluate, contact,
                    family_views_aligned=req.family_views_aligned,
                    family_perspective_summary=req.family_perspective_summary,
                    serious_relationship_aligned=req.serious_relationship_aligned,
                    marriage_expectations_aligned=req.marriage_expectations_aligned,
                    independence_aligned=req.independence_aligned)
