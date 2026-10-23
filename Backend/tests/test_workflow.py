import os, sys, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
os.environ["APP_API_KEY"] = "test-key"

from fastapi.testclient import TestClient
from app.main import app

client = TestClient(app)
H = {"X-API-Key": "test-key"}
NOW = 1_700_000_000.0


def _create(username="aisha.k", **over):
    body = {"username": username, "how_known": "mutual_follow", "adult_confirmed": True,
            "shared_interest": "photography"}
    body.update(over)
    r = client.post("/workflow/contacts", headers=H, json=body)
    assert r.status_code == 200, r.text
    return r.json()


# --- manual-add gates ---
def test_create_requires_adult_confirmation():
    r = client.post("/workflow/contacts", headers=H,
                    json={"username": "x.y", "how_known": "mutual_follow", "adult_confirmed": False})
    assert r.status_code == 422

def test_create_rejects_stranger_discovery_basis():
    r = client.post("/workflow/contacts", headers=H,
                    json={"username": "x.y", "how_known": "found_in_search", "adult_confirmed": True})
    assert r.status_code == 422

def test_community_recording_requires_permission():
    r = client.post("/workflow/contacts", headers=H,
                    json={"username": "x.y", "how_known": "mutual_follow", "adult_confirmed": True,
                          "community_volunteered": "Dudekula", "community_permission_to_record": False})
    assert r.status_code == 422
    ok = _create("c.d", community_volunteered="Dudekula", community_permission_to_record=True)
    assert ok["community_volunteered"] == "Dudekula"

def test_workflow_requires_auth():
    assert client.get("/workflow/contacts").status_code == 401
    assert client.get("/workflow/reminders").status_code == 401


# --- drafts never send; 48h rule ---
def test_intro_draft_does_not_send():
    c = _create("draft.only")
    r = client.post(f"/workflow/contacts/{c['id']}/intro-draft", headers=H, json={"language": "roman_urdu"})
    assert r.status_code == 200
    body = r.json()
    assert body["sent"] is False and "photography" in body["draft"]
    lst = client.get("/workflow/contacts", headers=H).json()["contacts"]
    mine = [x for x in lst if x["id"] == c["id"]][0]
    assert mine["status"] == "added" and mine["intro_sent_at"] is None

def test_followup_only_after_48h_and_only_once():
    c = _create("wait.48h")
    cid = c["id"]
    client.post(f"/workflow/contacts/{cid}/record-intro-sent", headers=H, json={"sent_at": NOW})
    r = client.post(f"/workflow/contacts/{cid}/followup-draft", headers=H,
                    json={"language": "english", "now": NOW + 3600})
    assert r.status_code == 422  # too early
    r = client.get("/workflow/reminders", headers=H, params={"now": NOW + 3600})
    assert all(x["contact_id"] != cid for x in r.json()["reminders"])
    r = client.get("/workflow/reminders", headers=H, params={"now": NOW + 49 * 3600})
    assert any(x["contact_id"] == cid and x["action"] == "review_no_reply" for x in r.json()["reminders"])
    r = client.post(f"/workflow/contacts/{cid}/followup-draft", headers=H,
                    json={"language": "roman_telugu", "now": NOW + 49 * 3600})
    assert r.status_code == 200 and r.json()["sent"] is False
    r = client.post(f"/workflow/contacts/{cid}/followup-draft", headers=H,
                    json={"language": "english", "now": NOW + 50 * 3600})
    assert r.status_code == 422  # only once

def test_no_reply_after_followup_closes_contact():
    c = _create("close.me")
    cid = c["id"]
    client.post(f"/workflow/contacts/{cid}/record-intro-sent", headers=H, json={"sent_at": NOW})
    client.post(f"/workflow/contacts/{cid}/followup-draft", headers=H, json={"now": NOW + 49 * 3600})
    client.post(f"/workflow/contacts/{cid}/record-followup-sent", headers=H, json={"sent_at": NOW + 49 * 3600})
    r = client.get("/workflow/reminders", headers=H, params={"now": NOW + 98 * 3600})
    assert any(x["contact_id"] == cid and x["action"] == "closed_no_reply" for x in r.json()["reminders"])
    r = client.post(f"/workflow/contacts/{cid}/intro-draft", headers=H, json={})
    assert r.status_code == 422  # closed: no further drafts

def test_declined_closes_immediately():
    c = _create("said.no")
    client.post(f"/workflow/contacts/{c['id']}/record-declined", headers=H)
    r = client.post(f"/workflow/contacts/{c['id']}/intro-draft", headers=H, json={})
    assert r.status_code == 422


# --- import, language, behaviour ---
GOOD_CHAT = [
    {"text": "Assalamualaikum, tum kaise ho? Photography mein kab se interest hai?", "sender": "other"},
    {"text": "Mein theek hoon, college ke baad start kiya tha", "sender": "me"},
    {"text": "Thanks for asking! Mein bhi portraits leti hoon, tum kya shoot karte ho?", "sender": "other"},
    {"text": "Mostly street scenes, tumhari favourite jagah kaunsi hai?", "sender": "me"},
    {"text": "No problem, take your time reply karna. Mein old city jaati hoon, wahan light bohat achi hoti hai, tum kab gaye the?", "sender": "other"},
    {"text": "Last month gaya tha, sorry late reply, kaam tha", "sender": "me"},
    {"text": "I like honest conversations, thanks. Tum apne goals ke baare mein batao, kya plan hai aage?", "sender": "other"},
    {"text": "Goal hai ek chhoti studio kholna, tumhara kya dream hai?", "sender": "me"},
]

def test_import_detects_language_and_green_flag():
    c = _create("good.chat")
    r = client.post(f"/workflow/contacts/{c['id']}/import-chat", headers=H, json={"messages": GOOD_CHAT})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["language"] in ("roman_urdu", "mixed_urdu_english")
    assert body["contact"]["status"] == "replied"
    assert body["behaviour"]["classification"] == "green_flag"
    assert body["behaviour"]["mutual_effort"] is True
    assert len(body["behaviour"]["positive_signals"]) >= 3

def test_behaviour_needs_more_information_for_short_chat():
    c = _create("short.chat")
    r = client.post(f"/workflow/contacts/{c['id']}/import-chat", headers=H,
                    json={"messages": [{"text": "hi", "sender": "other"}, {"text": "hello", "sender": "me"}]})
    assert r.json()["behaviour"]["classification"] == "needs_more_information"

def test_behaviour_flags_serious_pattern():
    c = _create("red.flag")
    msgs = [{"text": "send your photo right now, if you don't I will hurt you", "sender": "other"},
            {"text": "please don't say that", "sender": "me"}]
    r = client.post(f"/workflow/contacts/{c['id']}/import-chat", headers=H, json={"messages": msgs})
    b = r.json()["behaviour"]
    assert b["classification"] == "potential_red_flag" and b["concerns"]


# --- family questions + evaluation ---
def test_family_questions_require_real_conversation():
    c = _create("too.early")
    r = client.get(f"/workflow/contacts/{c['id']}/family-questions", headers=H)
    assert r.status_code == 422
    client.post(f"/workflow/contacts/{c['id']}/import-chat", headers=H, json={"messages": GOOD_CHAT})
    r = client.get(f"/workflow/contacts/{c['id']}/family-questions", headers=H)
    assert r.status_code == 200
    q = r.json()["questions"]
    assert "ghar wale" in q["open_ended"]["roman_urdu"]
    assert "intlo vallu" in q["open_ended"]["roman_telugu"]
    assert r.json()["sent"] is False

def test_evaluation_promising_produces_notification_and_pauses():
    c = _create("promising.one")
    client.post(f"/workflow/contacts/{c['id']}/import-chat", headers=H, json={"messages": GOOD_CHAT})
    r = client.post(f"/workflow/contacts/{c['id']}/evaluate", headers=H, json={
        "family_views_aligned": True, "family_perspective_summary": "She prefers convincing family first; I agree.",
        "serious_relationship_aligned": True, "marriage_expectations_aligned": True,
        "independence_aligned": True})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["compatibility_assessment"] == "promising"
    assert body["notification"].startswith("POTENTIAL COMPATIBLE MATCH FOUND")
    assert "ACTION REQUIRED" in body["notification"]
    # Never-leave-family answers are NOT a fail: perspective text is free-form;
    # only *alignment* matters.
    assert "convincing family first" in body["notification"]

def test_evaluation_uncertain_without_alignment():
    c = _create("not.yet")
    client.post(f"/workflow/contacts/{c['id']}/import-chat", headers=H, json={"messages": GOOD_CHAT})
    r = client.post(f"/workflow/contacts/{c['id']}/evaluate", headers=H, json={
        "family_views_aligned": None, "serious_relationship_aligned": True,
        "marriage_expectations_aligned": True, "independence_aligned": True})
    body = r.json()
    assert body["compatibility_assessment"] == "uncertain" and body["notification"] is None

def test_delete_contact_removes_everything():
    c = _create("delete.me")
    assert client.delete(f"/workflow/contacts/{c['id']}", headers=H).status_code == 200
    assert client.post(f"/workflow/contacts/{c['id']}/intro-draft", headers=H, json={}).status_code == 404
