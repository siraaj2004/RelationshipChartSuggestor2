# Approval-Only Relationship Workflow

Added 2026-10-23 as an extension of the Relationship AI Keyboard backend.
This workflow helps the user manage conversations **he starts himself, with
people he already knows**, in Roman Urdu, Roman Telugu, and English.

## Hard limits (enforced in code — `app/workflow.py`)

- **Manual contacts only.** No Instagram search, discovery, scraping,
  profile harvesting, or automated messaging exists anywhere in this API.
  Instagram offers no official integration for those actions.
- A contact requires `how_known` = `known_personally` | `mutual_follow` |
  `contacted_me_first`, plus `adult_confirmed: true`.
- **Nothing is sent by the server.** Endpoints prepare drafts; the user
  reviews, edits, and sends them himself in Instagram, then records that
  he did (`record-intro-sent` / `record-followup-sent`).
- **48-hour rule:** `GET /workflow/reminders` reminds the *user* only.
  One follow-up draft is allowed, only after 48h, only for someone he
  already knows. After a further 48h with no reply the contact is
  auto-closed (`closed_no_reply`). `record-declined` closes immediately.
- Community background is stored only if it was volunteered by the contact
  **and** recording was permitted. It is never inferred from a name, photo,
  or surname, and is never a character/compatibility score.
- Storage is in-memory only (like the scan relay), keyed by a hash of the
  app API key. `DELETE /workflow/contacts/{id}` removes a contact and all
  its imported messages immediately.

## Endpoints (all require `X-API-Key`)

| Method & path | Purpose |
|---|---|
| `POST /workflow/contacts` | Add a contact manually (gates above) |
| `GET /workflow/contacts` | List contacts (message counts, no message bodies) |
| `DELETE /workflow/contacts/{id}` | Delete contact + imported chat |
| `POST /workflow/contacts/{id}/intro-draft` | Friendly intro draft (EN / Roman Urdu / Roman Telugu). Never sent |
| `POST /workflow/contacts/{id}/record-intro-sent` | User confirms he sent it himself; starts the 48h clock |
| `GET /workflow/reminders` | Due reminders **for the user**; auto-closes after follow-up + 48h silence |
| `POST /workflow/contacts/{id}/followup-draft` | The single allowed follow-up draft, only after 48h |
| `POST /workflow/contacts/{id}/record-followup-sent` | User confirms he sent it himself |
| `POST /workflow/contacts/{id}/record-declined` | She said no → closed, no further drafts |
| `POST /workflow/contacts/{id}/import-chat` | Import a real chat → language detection + behaviour analysis |
| `GET /workflow/contacts/{id}/family-questions` | Open-ended + direct family-acceptance discussion drafts (only after a real mutual conversation: replied + ≥6 messages) |
| `POST /workflow/contacts/{id}/evaluate` | Compatibility evaluation; when Promising, returns the notification text and pauses the workflow for the user |

## Behaviour analysis

Classifications: `green_flag` (≥4 incoming messages **and** ≥3 distinct
positive signals **and** mutual effort), `potential_red_flag` (a serious
pattern observed: threat, coercion/control, blackmail, pressuring for
photos), otherwise `needs_more_information`. Every result includes the
evidence snippets and an uncertainty note. A person is never labelled
"toxic" from a single message.

## Compatibility evaluation

- **Condition 1 — behaviour:** green flag + mutual effort.
- **Condition 2 — long-term alignment:** the user supplies four booleans
  from what was actually discussed (serious-relationship, family-views,
  marriage-expectations, independence alignment). All four must be `true`.
- Agreement to leave family is **never** required. The family perspective
  is stored as a free-text summary exactly as stated (e.g. "prefers
  convincing family first") and only *alignment between the two people's
  stated views* counts.
- `promising` → response contains a `notification` beginning
  `POTENTIAL COMPATIBLE MATCH FOUND` and ending with the ACTION REQUIRED
  pause line. `uncertain` / `not_compatible` return no notification.

## Tests

`Backend/tests/test_workflow.py` (15 tests) covers the manual-add gates,
drafts-never-send, the 48h/one-follow-up/close rules, declined handling,
language detection on import, green / needs-more-info / red-flag
classification, family-question gating, promising vs uncertain evaluation,
and deletion. Full backend suite: 33 tests.
