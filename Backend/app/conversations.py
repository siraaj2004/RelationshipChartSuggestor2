"""Conversation validation, deduplication, language detection and analysis.

No Gemini call lives here — this module is pure and fully unit-tested, which is
what guarantees the acceptance rules (empty context -> no suggestions, dedup,
language labels) even before any model is involved.
"""
from __future__ import annotations

import re
from dataclasses import dataclass

TELUGU = {
    "nenu","nuuvu","nuvvu","meeru","vaadu","aame","adi","idi","ela","enti","enduku",
    "ekkada","eppudu","avunu","avuna","kaadu","ledu","ledhu","undi","undhi","vundhi","unna","chesa","chestunna","ra",
    "rey","raa","anna","annayya","akka","cheli","baaga","bagunna","bagunnava","chaala","konchem","ippudu","repu","ninna","monna",
    "tinnaava","velta","vastunna","ayyindi","kaavali","kavali","cheppu","cheppandi","choodu","chudu","vinava","vinu",
    "emiti","emi","em","entha","evaru","evadu","aithe","kani","mari","inka","ippude","akkada","ikkada","naaku","naku","neeku","neku",
    "manam","memu","appudu","tarvata","mundu","bangaram","istam","prema","chey","amma","nanna","babu",
    "nuv","nen","ipudu","epudu","ledha","undha","vastava","velthunna","velthunnav","chestava","chestunnav",
    "avuthundi","avuthunna","chestundi","chestunnadu","chestunnava","bagunnava","bagunna","bagunnav","cheppava","chustunna",
}
URDU = {
    "mein","tum","aap","hai","hain","nahi","kya","kyun","kyu","kahan","kab","kaise",
    "mera","meri","tumhara","uska","usko","isko","kisko","yeh","woh","bhi","aur","lekin","phir","abhi",
    "kal","aaj","bohat","bahut","acha","accha","theek","karo","karke","raha","rahi",
    "tha","thi","gaya","aaya","bolo","suno","sun","dekho","dekh","yaar","bhai","shukriya",
    "inshallah","mashallah","allah","kaisa","kaisi","ho","na","toh","matlab",
    "haan","han","ji","batao","bata","kuch","kabhi","chalo","zaroor","bilkul","bas",
    "mujhe","tujhe","jao","aao","ruk","samajh","dil","yaad","hamesha","jaan",
    "kesa","kesi","thik","bhot","boht","kr","kro","krna","krta","krti","rha","rhi","hua","hui",
    "aj","ab","tb","jb","sb","tm","ap","mjhe","kyon","shayad","lagta","lagti","chahiye","chaho","chahta","chahti","smjh",
}
ENGLISH = {
    "the","is","are","was","were","you","your","yours","what","when","where","why",
    "how","and","but","that","this","with","for","have","had","will","would","can",
    "could","should","did","do","does","going","want","really","because","about",
}

MAX_MESSAGES = 100
MAX_MESSAGE_CHARS = 2000


@dataclass
class Message:
    text: str
    sender: str  # me | other | unknown
    confidence: float = 1.0


def normalise(text: str) -> str:
    return re.sub(r"\s+", " ", text.strip().lower())


def _tokens(text: str) -> list[str]:
    return re.findall(r"[a-z']+", text.lower())


def _jaccard(a: str, b: str) -> float:
    sa, sb = set(_tokens(a)), set(_tokens(b))
    if not sa or not sb:
        return 0.0
    return len(sa & sb) / len(sa | sb)


def deduplicate(messages: list[Message]) -> list[Message]:
    """Drop same-sender duplicates: exact normalised match or Jaccard >= 0.85.
    Keeps the higher-confidence reading."""
    kept: list[Message] = []
    for msg in messages:
        dup_idx = next(
            (i for i, k in enumerate(kept)
             if k.sender == msg.sender and (normalise(k.text) == normalise(msg.text) or _jaccard(k.text, msg.text) >= 0.85)),
            None,
        )
        if dup_idx is not None:
            if msg.confidence > kept[dup_idx].confidence:
                kept[dup_idx] = msg
            continue
        kept.append(msg)
    return kept


def clean_messages(raw: list[Message]) -> list[Message]:
    cleaned = [
        Message(text=m.text.strip()[:MAX_MESSAGE_CHARS], sender=m.sender if m.sender in {"me", "other", "unknown"} else "unknown",
                confidence=max(0.0, min(1.0, float(m.confidence))))
        for m in raw if m.text and m.text.strip()
    ]
    return deduplicate(cleaned)[:MAX_MESSAGES]


def detect_language(messages: list[Message]) -> str:
    tokens = _tokens(" ".join(m.text for m in messages))
    # Single-token fix (2026-10-27): a lone Roman word like "haan"
    # used to fall through to "english"; with no marker evidence it
    # is "unknown", so the caller can fall back to the chat language.
    if not tokens:
        return "unknown"
    if len(tokens) == 1:
        if tokens[0] in TELUGU:
            return "roman_telugu"
        if tokens[0] in URDU:
            return "roman_urdu"
        if tokens[0] in ENGLISH:
            return "english"
        return "unknown"
    te = sum(t in TELUGU for t in tokens)
    ur = sum(t in URDU for t in tokens)
    en = sum(t in ENGLISH for t in tokens)
    en_ratio = en / max(len(tokens), 1)
    if te and ur:
        return ("mixed_telugu_english" if te >= ur else "mixed_urdu_english") if en_ratio > 0.15 else ("roman_telugu" if te >= ur else "roman_urdu")
    if te:
        return "mixed_telugu_english" if en >= 2 and en_ratio > 0.12 else "roman_telugu"
    if ur:
        return "mixed_urdu_english" if en >= 2 and en_ratio > 0.12 else "roman_urdu"
    return "english" if en else "unknown"


def detect_reply_language(messages: list[Message]) -> str:
    """Language replies should be written in: the other person's language
    first, not the whole chat's. A chat can switch language — e.g. he
    wrote Roman Telugu earlier and she now writes English — and detecting
    over every message then wrongly keeps replies in Roman Telugu. So:
    detect from incoming ('other') messages; only if they give no evidence
    (unknown) fall back to the whole conversation."""
    incoming = [m for m in messages if m.sender == "other"]
    if incoming:
        lang = detect_language(incoming)
        if lang != "unknown":
            return lang
    return detect_language(messages)


def latest_incoming(messages: list[Message]) -> Message | None:
    for m in reversed(messages):
        if m.sender == "other":
            return m
    return messages[-1] if messages else None


def heuristic_tone(messages: list[Message]) -> str:
    """Coarse local tone used only as a fallback label in /analyze-chat when the
    model is unavailable — it never generates reply text."""
    text = " ".join(m.text.lower() for m in messages)
    if any(w in text for w in ("sorry", "please don't", "stop", "leave me", "uncomfortable")):
        return "sensitive"
    if text.count("😂") or text.count("🤣") or "haha" in text or "lol" in text:
        return "humorous"
    if any(w in text for w in ("love", "miss you", "jaan", "bangaram")):
        return "romantic"
    if any(w in text for w in ("exam", "job", "family problem", "hospital", "tension")):
        return "serious"
    return "casual" if messages else "unknown"
