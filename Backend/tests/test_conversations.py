import os, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ["APP_API_KEY"] = "test-key"  # unconditional: tests must be hermetic even when CI exports its own APP_API_KEY

from fastapi.testclient import TestClient
from app import conversations as conv
from app.main import app

client = TestClient(app)
H = {"X-API-Key": "test-key"}
M = conv.Message


# --- language detection ---
def test_roman_telugu():
    msgs = [M("nenu baaga unna, nuvvu ela unnav?", "other"), M("nenu kuda baaga unna", "me")]
    assert conv.detect_language(msgs) == "roman_telugu"

def test_roman_urdu():
    msgs = [M("tum kahan ho, kya kar rahe ho?", "other"), M("mein ghar par hoon", "me")]
    assert conv.detect_language(msgs) == "roman_urdu"

def test_english():
    msgs = [M("what are you doing this weekend?", "other"), M("I was thinking about the movie", "me")]
    assert conv.detect_language(msgs) == "english"

def test_mixed_telugu_english():
    msgs = [M("nenu tomorrow office ki velta, meeting is there", "me")]
    assert conv.detect_language(msgs) in ("mixed_telugu_english", "roman_telugu")

def test_mixed_urdu_english():
    msgs = [M("mein kal busy hoon because office mein meeting hai", "me")]
    assert conv.detect_language(msgs) in ("mixed_urdu_english", "roman_urdu")

def test_unknown_for_gibberish():
    assert conv.detect_language([M("zxqw plmn", "other")]) == "unknown"


# --- deduplication ---
def test_dedup_exact_and_fuzzy():
    msgs = [
        M("hello how are you", "other", 0.5),
        M("Hello how are you", "other", 0.9),                    # exact dupe -> higher confidence wins
        M("i am going to the market today evening", "other", 0.8),
        M("i am going to the market today", "other", 0.7),       # fuzzy dupe (Jaccard 7/8 >= 0.85) -> dropped
        M("hello how are you", "me", 0.9),                       # different sender -> kept
    ]
    out = conv.deduplicate(msgs)
    assert len(out) == 3
    assert out[0].confidence == 0.9

def test_clean_drops_empty():
    assert conv.clean_messages([M("  ", "me"), M("hi", "me")]) == [M("hi", "me")]


# --- API behaviour ---
def test_health():
    r = client.get("/health")
    assert r.status_code == 200 and r.json()["status"] == "ok"

def test_auth_required():
    r = client.post("/generate-replies", json={"messages": [{"text": "hi", "sender": "other"}]})
    assert r.status_code == 401

def test_empty_context_rejected():
    r = client.post("/generate-replies", headers=H, json={"messages": []})
    assert r.status_code == 422

def test_no_gemini_key_means_no_invented_suggestions():
    # With GEMINI_API_KEY unset the endpoint must fail honestly (503), never fabricate.
    os.environ.pop("GEMINI_API_KEY", None)
    r = client.post("/generate-replies", headers=H,
                    json={"messages": [{"text": "nenu baaga unna, nuvvu ela unnav?", "sender": "other"}]})
    assert r.status_code == 503

def test_generate_with_mocked_gemini(monkeypatch):
    import app.main as main
    async def fake(messages, language, context=None):
        return ["Nenu kuda baaga unna!", "Nuvvu em chestunnav ippudu?", "Evening call cheddama?"]
    monkeypatch.setattr(main.gemini, "generate_replies", fake)
    r = client.post("/generate-replies", headers=H,
                    json={"messages": [{"text": "nenu baaga unna", "sender": "other"}, {"text": "nuvvu ela unnav", "sender": "other"}]})
    assert r.status_code == 200
    body = r.json()
    assert len(body["suggestions"]) == 3
    assert body["language"] == "roman_telugu"
    assert body["based_on_message_count"] == 2

def test_generate_passes_user_context(monkeypatch):
    import app.main as main
    seen = {}
    async def fake(messages, language, context=None):
        seen["context"] = context
        return ["Reply one", "Reply two", "Reply three"]
    monkeypatch.setattr(main.gemini, "generate_replies", fake)
    r = client.post("/generate-replies", headers=H,
                    json={"messages": [{"text": "hi there", "sender": "other"}],
                          "context": {"days_chatting": 12, "goal": "get_closer", "tone": "sweet"}})
    assert r.status_code == 200
    assert seen["context"] is not None
    assert seen["context"].days_chatting == 12
    assert seen["context"].goal == "get_closer"
    assert seen["context"].tone == "sweet"

def test_context_line_rendering():
    from app import gemini
    from app.main import SuggestionContext
    line = gemini._context_line(SuggestionContext(days_chatting=12, goal="get_closer", tone="sweet"))
    assert "12 days" in line and "grow closer" in line and "sweet" in line
    assert gemini._context_line(None) == ""
    assert gemini._context_line(SuggestionContext()) == ""

def test_invalid_context_rejected():
    r = client.post("/generate-replies", headers=H,
                    json={"messages": [{"text": "hi", "sender": "other"}],
                          "context": {"days_chatting": -3}})
    assert r.status_code == 422
