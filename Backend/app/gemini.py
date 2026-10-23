"""Gemini integration.

The API key exists ONLY here, on the server, read from the environment.
Calls go to the Gemini REST API with a JSON response schema, a hard timeout,
and strict post-validation. If Gemini is unconfigured or returns anything
that is not exactly 3 usable, distinct replies, this raises — the API then
returns an error and the client shows NO suggestions. It never falls back to
invented replies.
"""
from __future__ import annotations

import json
import os

import httpx

GEMINI_MODEL = os.environ.get("GEMINI_MODEL", "gemini-3.8-flash")
GEMINI_URL = f"https://generativelanguage.googleapis.com/v1beta/models/{GEMINI_MODEL}:generateContent"
TIMEOUT = httpx.Timeout(45.0, connect=5.0)

SYSTEM_RULES = """You write reply suggestions for the user ("me") in a private chat.
Rules you must follow:
- Base replies ONLY on the conversation provided. Never invent shared history, names, plans or facts that are not in it.
- Reply in the SAME language and script as the conversation (Roman Telugu, Roman Urdu, English, or the same mix). Do not translate unless the conversation does.
- Match the tone and spelling style of the user's own previous messages.
- Produce exactly 3 replies that are meaningfully different from each other (e.g. warm/short, playful, and a question that continues the topic).
- Sound like a real person texting. No generic filler like "That's interesting" on its own.
- Respect boundaries: if the other person shows disinterest, distance, or discomfort, replies must be low-pressure, brief, and leave the door open to end the chat. Never suggest guilt-tripping, jealousy tactics, love-bombing, manipulation, deception, or pressuring for replies/photos/meetings.
- Keep each reply under 240 characters unless the conversation's style is clearly longer.
"""


class GeminiNotConfigured(RuntimeError):
    pass


class GeminiResponseError(RuntimeError):
    pass


def _api_key() -> str:
    key = os.environ.get("GEMINI_API_KEY", "").strip()
    if not key:
        raise GeminiNotConfigured("GEMINI_API_KEY is not set on the server")
    return key


def _transcript(messages) -> str:
    lines = []
    for m in messages:
        who = {"me": "ME", "other": "THEM", "unknown": "UNKNOWN"}.get(m.sender, "UNKNOWN")
        lines.append(f"{who}: {m.text}")
    return "\n".join(lines)


async def _call_gemini(prompt: str, schema: dict) -> dict:
    payload = {
        "systemInstruction": {"parts": [{"text": SYSTEM_RULES}]},
        "contents": [{"role": "user", "parts": [{"text": prompt}]}],
        "generationConfig": {
            "responseMimeType": "application/json",
            "responseSchema": schema,
            # Gemini 3.x Flash "thinks" at medium level by default, which made
            # even tiny replies exceed the read timeout. thinkingBudget is the
            # retired 2.5 knob and is ignored here; thinkingLevel "low" is the
            # documented fast setting on gemini-3.8-flash. (temperature is also
            # deprecated on 3.x, so it is not sent.)
            "thinkingConfig": {"thinkingLevel": "low"},
        },
    }
    # trust_env=False: a direct server->Google call must not inherit ambient
    # proxy env vars (which can be malformed for httpx and break every request).
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT, trust_env=False) as client:
            resp = await client.post(GEMINI_URL, params={"key": _api_key()}, json=payload)
    except httpx.TimeoutException as exc:
        raise GeminiResponseError("Gemini took too long to respond") from exc
    except httpx.HTTPError as exc:
        raise GeminiResponseError(f"Could not reach Gemini: {exc}") from exc
    if resp.status_code != 200:
        raise GeminiResponseError(f"Gemini HTTP {resp.status_code}: {resp.text[:300]}")
    try:
        text = resp.json()["candidates"][0]["content"]["parts"][0]["text"]
        return json.loads(text)
    except (KeyError, IndexError, TypeError, json.JSONDecodeError) as exc:
        raise GeminiResponseError(f"Unparseable Gemini response: {exc}") from exc


async def generate_replies(messages, language: str) -> list[str]:
    schema = {
        "type": "OBJECT",
        "properties": {"suggestions": {"type": "ARRAY", "items": {"type": "STRING"}}},
        "required": ["suggestions"],
    }
    prompt = (
        f"Detected conversation language: {language}\n\nConversation:\n{_transcript(messages)}\n\n"
        "Write exactly 3 reply suggestions for ME to send next."
    )
    data = await _call_gemini(prompt, schema)
    raw = data.get("suggestions") or []
    clean = [s.strip() for s in raw if isinstance(s, str) and s.strip()]
    # Distinctness + count are acceptance rules, not niceties.
    deduped = list(dict.fromkeys(clean))
    if len(deduped) != 3:
        raise GeminiResponseError(f"Expected exactly 3 distinct suggestions, got {len(deduped)}")
    return deduped


async def analyze(messages, language: str) -> dict:
    schema = {
        "type": "OBJECT",
        "properties": {
            "tone": {"type": "STRING"},
            "topic": {"type": "STRING"},
            "summary": {"type": "STRING"},
        },
        "required": ["tone", "topic", "summary"],
    }
    prompt = (
        f"Detected conversation language: {language}\n\nConversation:\n{_transcript(messages)}\n\n"
        "Analyse it: tone must be one of casual, friendly, romantic, serious, sensitive, humorous; "
        "topic is a short phrase; summary is one sentence about where the conversation stands. "
        "Describe only what is in the conversation."
    )
    data = await _call_gemini(prompt, schema)
    tone = data.get("tone", "unknown")
    if tone not in {"casual", "friendly", "romantic", "serious", "sensitive", "humorous"}:
        tone = "unknown"
    return {"tone": tone, "topic": str(data.get("topic", ""))[:120], "summary": str(data.get("summary", ""))[:500]}
