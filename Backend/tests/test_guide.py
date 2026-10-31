"""Guide mode validation (pure, no network, no Gemini key needed)."""
import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from app import gemini


def test_guide_send_valid():
    r = gemini.validate_guide({
        "decision": "send",
        "reason": "She sent last and sounds tired",
        "action": "Send one caring, low-pressure message",
        "suggestions": ["take care, rest well", "how are you feeling now?", "here if you want to talk"],
    })
    assert r["decision"] == "send" and len(r["suggestions"]) == 3


def test_guide_wait_valid_and_lowercased():
    r = gemini.validate_guide({
        "decision": "WAIT",
        "reason": "You sent last and she has not replied yet",
        "action": "Wait for her reply, do not double-text",
        "suggestions": ["later 1", "later 2", "later 3"],
    })
    assert r["decision"] == "wait"


def test_guide_rejects_bad_decision():
    try:
        gemini.validate_guide({
            "decision": "maybe", "reason": "x", "action": "y",
            "suggestions": ["a", "b", "c"],
        })
    except gemini.GeminiResponseError:
        return
    raise AssertionError("bad decision was not rejected")


def test_guide_rejects_wrong_suggestion_count_or_duplicates():
    for suggestions in (["a", "b"], ["a", "a", "b"], []):
        try:
            gemini.validate_guide({
                "decision": "send", "reason": "x", "action": "y",
                "suggestions": suggestions,
            })
        except gemini.GeminiResponseError:
            continue
        raise AssertionError(f"suggestions {suggestions!r} were not rejected")


def test_guide_relay_store_and_latest():
    """Guide relay (new in 1.13.0): /guide-store holds only the
    decision, and /guide-latest returns it; deleting clears it."""
    os.environ["APP_API_KEY"] = "test-key"
    from fastapi.testclient import TestClient
    from app.main import app
    client = TestClient(app)
    h = {"X-API-Key": "test-key"}
    assert client.get("/guide-latest", headers=h).status_code == 404
    r = client.post("/guide-store", json={
        "decision": "wait", "reason": "You sent last, no reply yet",
        "action": "Wait for her reply", "based_on_message_count": 25,
    }, headers=h)
    assert r.status_code == 200
    r = client.get("/guide-latest", headers=h)
    assert r.status_code == 200
    body = r.json()
    assert body["decision"] == "wait" and body["based_on_message_count"] == 25
    assert "suggestions" not in body  # Wait drafts are never in the relay
    assert client.delete("/guide-latest", headers=h).status_code == 200
    assert client.get("/guide-latest", headers=h).status_code == 404


def test_guide_rejects_empty_reason_or_action():
    for payload in (
        {"decision": "send", "reason": "", "action": "y", "suggestions": ["a", "b", "c"]},
        {"decision": "send", "reason": "x", "action": "", "suggestions": ["a", "b", "c"]},
    ):
        try:
            gemini.validate_guide(payload)
        except gemini.GeminiResponseError:
            continue
        raise AssertionError(f"payload {payload!r} was not rejected")
