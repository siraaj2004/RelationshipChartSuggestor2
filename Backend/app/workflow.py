"""Approval-only relationship workflow.

Design rules (enforced in code, not just documented):

- Contacts are added MANUALLY by the user. There is no discovery, search,
  scraping, or Instagram automation in this module or anywhere in the backend.
- A contact can only be added when the user confirms: (a) they already know
  this person, follow each other mutually, or the person contacted them
  first, and (b) the person is an adult to the user's knowledge.
- Nothing is ever sent. This module only prepares DRAFTS for the user's
  approval and records actions the user confirms they took themselves
  inside Instagram.
- The 48-hour scheduler reminds the USER only. It never messages, tags, or
  comments to the other person.
- After one user-sent follow-up and a further 48 hours with no reply, the
  contact is closed. A contact who declined is closed immediately and no
  further drafts are produced.
- Community background is never inferred. It is stored only when the user
  states it was volunteered by the contact AND recording was permitted.
- Behaviour analysis is evidence-based and conservative: a "green flag"
  requires multiple consistent positive signals across several incoming
  messages; a single message can never produce it, and one rude message
  produces "potential red flag" only when it matches a serious pattern
  (threat, coercion, blackmail, persistent-boundary language).
- Compatibility never requires agreement to leave family. The family
  perspective is summarised as stated; *alignment* between the two people's
  stated views is a separate, user-supplied judgement.

State is held in memory only (keyed by a hash of the caller's app key),
mirroring the scan relay: nothing is written to disk, and data disappears
when the service restarts or the contact is deleted.
"""
from __future__ import annotations

import hashlib
import re
import time
import uuid

from . import conversations as conv

FOLLOWUP_AFTER_SECONDS = 48 * 3600

HOW_KNOWN_ALLOWED = {"known_personally", "mutual_follow", "contacted_me_first"}

CONTACT_STATUSES = {
    "added", "waiting_reply", "waiting_after_followup", "replied",
    "closed_no_reply", "declined", "promising_ready_for_user",
}
CLOSED_STATUSES = {"closed_no_reply", "declined"}

# --- In-memory store: {owner_hash: {contact_id: contact_dict}} ----------------
_store: dict[str, dict[str, dict]] = {}


def _owner(api_key: str) -> str:
    return hashlib.sha256(api_key.encode()).hexdigest()


def _contacts(api_key: str) -> dict[str, dict]:
    return _store.setdefault(_owner(api_key), {})


def reset(api_key: str) -> None:
    _store.pop(_owner(api_key), None)


def get_contact(api_key: str, contact_id: str) -> dict | None:
    return _contacts(api_key).get(contact_id)


def _public(contact: dict) -> dict:
    out = {k: v for k, v in contact.items() if k != "messages"}
    out["message_count"] = len(contact.get("messages", []))
    return out


def list_contacts(api_key: str) -> list[dict]:
    return [_public(c) for c in _contacts(api_key).values()]


# --- Creation ------------------------------------------------------------------
class WorkflowError(ValueError):
    """Raised for rule violations; the API layer maps it to HTTP 422/409."""


def create_contact(api_key: str, *, username: str, how_known: str,
                   adult_confirmed: bool, shared_interest: str = "",
                   community_volunteered: str = "",
                   community_permission_to_record: bool = False) -> dict:
    username = username.strip().lstrip("@")
    if not username or len(username) > 64 or not re.fullmatch(r"[A-Za-z0-9._]+", username):
        raise WorkflowError("Username must be a plain Instagram username (letters, digits, '.' or '_')")
    if how_known not in HOW_KNOWN_ALLOWED:
        raise WorkflowError(
            "Contacts may only be added when you know them personally, follow each other mutually, "
            "or they contacted you first")
    if adult_confirmed is not True:
        raise WorkflowError("You must confirm this person is an adult before adding them")
    community = ""
    if community_volunteered:
        if not community_permission_to_record:
            raise WorkflowError(
                "Community background can only be recorded when she volunteered it and permitted recording it")
        community = community_volunteered.strip()[:80]
    contact = {
        "id": uuid.uuid4().hex,
        "username": username,
        "how_known": how_known,
        "adult_confirmed": True,
        "shared_interest": shared_interest.strip()[:200],
        "community_volunteered": community,
        "status": "added",
        "preferred_language": "unknown",
        "intro_sent_at": None,
        "followup_sent_at": None,
        "followup_draft_used": False,
        "created_at": time.time(),
        "messages": [],
        "last_evaluation": None,
    }
    _contacts(api_key)[contact["id"]] = contact
    return _public(contact)


def delete_contact(api_key: str, contact_id: str) -> bool:
    return _contacts(api_key).pop(contact_id, None) is not None


# --- Drafts (never sent) ---------------------------------------------------------
_INTRO_TEMPLATES = {
    "english": "Hi {name}, I enjoyed your post about {interest}. I work/study around similar things too — how did you get into it?",
    "roman_urdu": "Assalamualaikum {name}, mujhe aapki {interest} wali post achi lagi. Main bhi isi mein interest rakhta hoon — aap ko iska shauq kaise hua?",
    "roman_telugu": "Hi {name}, mee {interest} gurinchi post chala bagundi. Nenu kuda daniki related gaane untanu — meeku ee interest ela start ayyindi?",
}
_FOLLOWUP_TEMPLATES = {
    "english": "Hey, I sent you a message in your inbox. Feel free to check it whenever you're comfortable 😊",
    "roman_urdu": "Hey, maine aapko inbox mein message kiya tha. Agar aap comfortable hain toh dekh lijiyega 😊",
    "roman_telugu": "Hey, neeku inbox lo message chesanu. Neeku interest unte okasari choodu 😊",
}


def _require_open(contact: dict) -> None:
    if contact["status"] in CLOSED_STATUSES:
        raise WorkflowError(f"Contact is {contact['status']} — no further drafts or contact", )


def intro_draft(contact: dict, language: str = "english") -> dict:
    _require_open(contact)
    tpl = _INTRO_TEMPLATES.get(language, _INTRO_TEMPLATES["english"])
    interest = contact.get("shared_interest") or "the topic you post about"
    return {
        "draft": tpl.format(name=contact["username"], interest=interest),
        "language": language if language in _INTRO_TEMPLATES else "english",
        "sent": False,
        "note": "Draft only. Review, edit, and send it yourself in Instagram if you choose to.",
    }


def followup_draft(contact: dict, language: str = "english", now: float | None = None) -> dict:
    _require_open(contact)
    if contact["status"] != "waiting_reply" or not contact.get("intro_sent_at"):
        raise WorkflowError("A follow-up is only available after an intro you sent yourself has waited 48 hours")
    now = time.time() if now is None else now
    if now - contact["intro_sent_at"] < FOLLOWUP_AFTER_SECONDS:
        raise WorkflowError("48 hours have not passed since the intro yet")
    if contact.get("followup_draft_used"):
        raise WorkflowError("Only one follow-up draft is allowed")
    contact["followup_draft_used"] = True
    tpl = _FOLLOWUP_TEMPLATES.get(language, _FOLLOWUP_TEMPLATES["english"])
    return {
        "draft": tpl,
        "language": language if language in _FOLLOWUP_TEMPLATES else "english",
        "sent": False,
        "note": "Draft only, and only for someone you already know. If there is still no reply after this, the contact closes.",
    }


# --- Recording actions the USER took ---------------------------------------------
def record_intro_sent(contact: dict, sent_at: float | None = None) -> dict:
    _require_open(contact)
    contact["intro_sent_at"] = time.time() if sent_at is None else sent_at
    contact["status"] = "waiting_reply"
    return _public(contact)


def record_followup_sent(contact: dict, sent_at: float | None = None) -> dict:
    _require_open(contact)
    if not contact.get("followup_draft_used"):
        raise WorkflowError("Prepare the follow-up draft first — only one, drafted after 48 hours")
    contact["followup_sent_at"] = time.time() if sent_at is None else sent_at
    contact["status"] = "waiting_after_followup"
    return _public(contact)


def record_declined(contact: dict) -> dict:
    contact["status"] = "declined"
    return _public(contact)


# --- Reminders (to the user only) ---------------------------------------------
def due_reminders(api_key: str, now: float | None = None) -> list[dict]:
    now = time.time() if now is None else now
    out = []
    for c in _contacts(api_key).values():
        if c["status"] == "waiting_reply" and c.get("intro_sent_at") \
                and now - c["intro_sent_at"] >= FOLLOWUP_AFTER_SECONDS:
            out.append({"contact_id": c["id"], "username": c["username"],
                        "action": "review_no_reply",
                        "options": ["prepare_one_followup_draft (only if you know her)",
                                    "close_contact"]})
        elif c["status"] == "waiting_after_followup" and c.get("followup_sent_at") \
                and now - c["followup_sent_at"] >= FOLLOWUP_AFTER_SECONDS:
            c["status"] = "closed_no_reply"
            out.append({"contact_id": c["id"], "username": c["username"],
                        "action": "closed_no_reply",
                        "options": []})
    return out


# --- Conversation import + behaviour analysis ---------------------------------
_POSITIVE_PATTERNS = {
    "asks questions back": re.compile(r"\?\s*$|\?\s", re.M),
    "thanks / appreciation": re.compile(r"\b(thank|thanks|shukriya|dhanyavaadalu)\b", re.I),
    "respectful of time / pace": re.compile(r"\b(take your time|no problem|no worries|aram se|parledu|koi baat nahi)\b", re.I),
    "apologises appropriately": re.compile(r"\b(sorry|maaf|kshaminchandi)\b", re.I),
    "shares about herself": re.compile(r"\b(i (like|love|study|work|enjoy)|nenu .* chestanu|mein .* karti)\b", re.I),
}
_SERIOUS_PATTERNS = {
    "threat": re.compile(r"\b(i will hurt|i'll hurt|maar dunga|kodata|harm you|leak your)\b", re.I),
    "coercion / control": re.compile(r"\b(you must not talk|don't talk to (him|her|them)|block him|block her|you are not allowed)\b", re.I),
    "blackmail": re.compile(r"\b(if you don't|if you dont).*(photo|pic|chat).*(send|share|post)\b", re.I),
    "pressuring for photos": re.compile(r"\b(send (me )?(your )?(photo|pic|selfie)s? (now|right now))\b", re.I),
}


def analyse_behaviour(messages: list[conv.Message]) -> dict:
    incoming = [m for m in messages if m.sender == "other"]
    outgoing = [m for m in messages if m.sender == "me"]
    positives: list[dict] = []
    for label, pat in _POSITIVE_PATTERNS.items():
        hits = [m.text for m in incoming if pat.search(m.text)]
        if hits:
            positives.append({"signal": label, "count": len(hits), "evidence": hits[0][:160]})
    concerns: list[dict] = []
    for label, pat in _SERIOUS_PATTERNS.items():
        hits = [m.text for m in incoming if pat.search(m.text)]
        if hits:
            concerns.append({"signal": label, "count": len(hits), "evidence": hits[0][:160]})
    # Mutual effort: she writes a comparable share, not one-word replies only.
    avg_in_len = sum(len(m.text.split()) for m in incoming) / len(incoming) if incoming else 0
    mutual_effort = bool(incoming and outgoing and len(incoming) >= max(2, len(outgoing) // 2) and avg_in_len >= 3)
    if mutual_effort:
        positives.append({"signal": "mutual effort in conversation",
                          "count": len(incoming),
                          "evidence": f"{len(incoming)} incoming messages, average {avg_in_len:.0f} words"})

    if concerns:
        classification = "potential_red_flag"
    elif len(incoming) >= 4 and len(positives) >= 3:
        classification = "green_flag"
    else:
        classification = "needs_more_information"
    return {
        "classification": classification,
        "positive_signals": positives,
        "concerns": concerns,
        "mutual_effort": mutual_effort,
        "incoming_message_count": len(incoming),
        "outgoing_message_count": len(outgoing),
        "uncertainty": "Based only on the messages imported so far. One conversation cannot establish character; "
                       "a green flag requires the pattern to stay consistent over time.",
    }


def import_chat(api_key: str, contact: dict, raw_messages: list[conv.Message]) -> dict:
    _require_open(contact)
    messages = conv.clean_messages(raw_messages)
    if not messages:
        raise WorkflowError("No usable messages in the imported chat")
    contact["messages"] = messages
    contact["preferred_language"] = conv.detect_language(messages)
    if any(m.sender == "other" for m in messages):
        contact["status"] = "replied"
    analysis = analyse_behaviour(messages)
    return {"contact": _public(contact), "language": contact["preferred_language"],
            "behaviour": analysis}


# --- Family-acceptance discussion drafts -----------------------------------------
FAMILY_QUESTIONS = {
    "open_ended": {
        "roman_urdu": "Agar do log ek doosre se sach mein pyaar karte hain, lekin ghar wale unke rishte ke liye raazi nahi hote, toh tumhare khayal mein unhein kya karna chahiye?",
        "english": "If two people genuinely love each other but their families don't approve, what do you think they should do?",
        "roman_telugu": "Oka abbayi ammayi nijamga preminchukuntunnaru anuko, kani intlo vallu oppukokapothe, nee opinion lo vallu em cheyyali?",
    },
    "direct_hypothetical": {
        "roman_urdu": "Agar ghar wale bilkul nahi maanein, toh kya tum apni marzi se apne partner ke saath jaane ka faisla karogi, ya pehle family ko samjhane ki koshish karogi?",
        "english": "If your family didn't agree to your relationship, would you ever consider leaving home voluntarily with your partner, or would you prefer trying to convince your family first?",
        "roman_telugu": "Okavela intlo vallu assalu oppukokapothe, nuvvu nee partner tho nee ishtam tho velladaniki ready avuthava? Leda mundu family ni convince cheyadaniki try chesthava?",
    },
}


def family_questions(contact: dict) -> dict:
    _require_open(contact)
    if contact["status"] not in {"replied", "promising_ready_for_user"} or len(contact.get("messages", [])) < 6:
        raise WorkflowError("Family questions are only suggested after a real, mutual conversation is under way "
                            "(replied status and at least 6 imported messages)")
    return {"questions": FAMILY_QUESTIONS, "sent": False,
            "note": "Discussion drafts only, for a comfortable, reciprocal conversation between adults. "
                    "Respect any answer, including that she would never leave her family."}


# --- Compatibility evaluation ------------------------------------------------------
def evaluate(contact: dict, *, family_views_aligned: bool | None,
             family_perspective_summary: str = "",
             serious_relationship_aligned: bool | None,
             marriage_expectations_aligned: bool | None,
             independence_aligned: bool | None) -> dict:
    messages = contact.get("messages", [])
    behaviour = analyse_behaviour(messages) if messages else {
        "classification": "needs_more_information", "positive_signals": [], "concerns": [],
        "mutual_effort": False, "incoming_message_count": 0, "outgoing_message_count": 0,
        "uncertainty": "No conversation imported yet."}

    condition1 = behaviour["classification"] == "green_flag" and behaviour["mutual_effort"]
    alignments = [serious_relationship_aligned, family_views_aligned,
                  marriage_expectations_aligned, independence_aligned]
    condition2 = all(a is True for a in alignments)
    if behaviour["classification"] == "potential_red_flag":
        assessment = "not_compatible"
    elif condition1 and condition2:
        assessment = "promising"
    else:
        assessment = "uncertain"

    result = {
        "behaviour": behaviour,
        "condition_1_relationship_behaviour": condition1,
        "condition_2_long_term_compatibility": condition2,
        "family_perspective_summary": family_perspective_summary.strip()[:400],
        "compatibility_assessment": assessment,
        "reason": _evaluation_reason(behaviour, condition1, condition2),
        "notification": None,
    }
    if assessment == "promising":
        contact["status"] = "promising_ready_for_user"
        result["notification"] = (
            "POTENTIAL COMPATIBLE MATCH FOUND\n"
            f"Instagram username: {contact['username']}\n"
            f"Preferred language: {contact['preferred_language']}\n"
            f"Conversation stage: mutual conversation under way ({len(messages)} imported messages)\n"
            f"Mutual interest: {len([p for p in behaviour['positive_signals']])} consistent positive signals; mutual effort observed\n"
            f"Positive behaviour: {', '.join(p['signal'] for p in behaviour['positive_signals']) or '—'}\n"
            f"Potential concerns: {', '.join(c['signal'] for c in behaviour['concerns']) or 'none observed in imported chat'}\n"
            f"Family acceptance perspective: {result['family_perspective_summary'] or 'discussed; views recorded as aligned'}\n"
            f"Compatibility assessment: Promising\n"
            f"Reason: {result['reason']}\n"
            "ACTION REQUIRED: A promising connection has developed. Review the conversation and decide "
            "whether you'd like to continue personally. The assisted workflow pauses here."
        )
    contact["last_evaluation"] = {k: v for k, v in result.items() if k != "notification"}
    return result


def _evaluation_reason(behaviour: dict, c1: bool, c2: bool) -> str:
    if behaviour["classification"] == "potential_red_flag":
        return "A serious concerning pattern was observed in the imported messages: " + \
               ", ".join(c["signal"] for c in behaviour["concerns"])
    if c1 and c2:
        return "Multiple consistent positive behaviour signals with mutual effort, and stated long-term views are aligned."
    if not c1:
        return "Behaviour evidence is not yet strong or consistent enough (needs more genuine conversation, not more pressure)."
    return "Behaviour looks positive, but long-term views are not yet confirmed as aligned."
