# Relationship AI Keyboard

An iPhone keyboard that suggests replies based on a conversation **you explicitly scan on screen** — not on examples, and never on data it doesn't have. With no scanned context, the suggestion bar is empty. That's by design.

Supports English, Roman Telugu, Roman Urdu, and Telugu/Urdu–English mixes, preserving the chat's own language and style.

## How it works

```
WhatsApp / Messenger / Telegram / Instagram
        │  you start a ReplayKit broadcast (system UI, your tap)
        ▼
BroadcastExtension (SampleHandler.swift) — Vision OCR on visible frames, on-device
        │  parsed, deduplicated text only (never video)
        ▼
App Group (SharedStore.swift) ──────────────► Main app: review, consent, delete
        │  you tap Generate Replies (consent required)
        ▼
FastAPI backend ──► Gemini (key stays on the server) ──► exactly 3 replies
        │
        ▼
KeyboardExtension — 3 suggestions in the bar; tapping inserts text. It never sends.
```

iOS limits that shape this design (stated honestly):
- A keyboard extension **cannot** start a screen broadcast or read another app. Scan Chat therefore opens the host app, where you start the broadcast in Apple's own picker UI.
- A keyboard **cannot** send a message for you, and this one wouldn't anyway: it only inserts text.
- Extensions have tight memory limits, so OCR is throttled (~1 frame/1.2s) and frames are discarded after OCR.

## Folder structure

```
project.yml                 XcodeGen project (app + keyboard + broadcast + tests)
Config/ExportOptions.plist  Signed export settings (fill in your team/profiles)
App/
  RelationshipApp.swift     App entry + AppModel
  Views/ChatScannerView.swift   ReplayKit picker, consent, scanned-chat review
  Views/HomeView.swift      Home + keyboard setup (Full Access explained)
  Views/SettingsView.swift  Backend URL/key, upload consent, retention, delete
  Services/APIClient.swift  Backend client (20s timeout, consent-gated)
Shared/                     Compiled into all three targets
  Models.swift  SharedStore.swift  ChatParsing.swift
  LanguageDetection.swift  OCRService.swift (Apple Vision)
KeyboardExtension/KeyboardViewController.swift   QWERTY, suggestion bar, emoji/globe/shift/symbols
BroadcastExtension/SampleHandler.swift           ReplayKit + Vision pipeline
Backend/
  app/main.py               GET /health, POST /analyze-chat, POST /generate-replies
  app/gemini.py             Gemini REST call, JSON schema, strict 3-reply validation
  app/conversations.py      Cleaning, dedup, language detection (pure, tested)
  requirements.txt  Dockerfile  .env.example
Tests/UnitTests/            Swift tests: parsing, language, store invariants
Tests/UITests/AcceptanceChecklist.md   Device acceptance script
.github/workflows/build.yml Backend tests + unsigned simulator build + signed IPA job
```

## Windows user? Start here

No Mac? Read **WINDOWS_TO_IPHONE.md** — build the IPA with GitHub Actions from your browser, then sign and install it from Windows with Sideloadly. Note the free-signing limits for keyboard extensions described there.

## 1. Run the backend

```bash
cd Backend
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # set GEMINI_API_KEY and a long random APP_API_KEY
set -a; source .env; set +a
uvicorn app.main:app --host 0.0.0.0 --port 8000
curl localhost:8000/health        # {"status":"ok","gemini_configured":true}
pytest -q                          # language, dedup, auth, empty-context, no-key honesty
# or: docker build -t relationship-backend . && docker run -p 8000:8000 --env-file .env relationship-backend
```
Put it behind HTTPS before using it from a device (any host with TLS, or a tunnel for local dev).

## 2. Build the iOS app

Requirements: Mac, Xcode 15.4+ (current SDK), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), an Apple Developer account for device installs.

```bash
# Change bundle IDs / team first if com.shaik.* isn't yours:
#   project.yml, all three .entitlements, SharedStore.appGroupID, ExportOptions.plist
xcodegen generate
open RelationshipAIKeyboard.xcodeproj
```

**Simulator (unsigned, for development):**
```bash
xcodebuild build -project RelationshipAIKeyboard.xcodeproj -scheme RelationshipAIKeyboard \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15' \
  CODE_SIGNING_ALLOWED=NO
xcodebuild test  -project RelationshipAIKeyboard.xcodeproj -scheme RelationshipAIKeyboard \
  -destination 'platform=iOS Simulator,name=iPhone 15' CODE_SIGNING_ALLOWED=NO
```
Note: ReplayKit broadcast and third-party keyboards behave fully only on a real device; the simulator is for UI/unit work.

**Device / IPA (signed — the only installable kind):**
1. In Xcode, select each target (app, keyboard, broadcast) → Signing & Capabilities: set your Team, unique bundle IDs, and the App Group `group.<your id>` on all three.
2. Create matching provisioning profiles in the Apple Developer portal (or let Xcode manage signing).
3. Archive: Product → Archive, or:
```bash
xcodebuild archive -project RelationshipAIKeyboard.xcodeproj -scheme RelationshipAIKeyboard \
  -archivePath build/RelationshipAIKeyboard.xcarchive
xcodebuild -exportArchive -archivePath build/RelationshipAIKeyboard.xcarchive \
  -exportOptionsPlist Config/ExportOptions.plist -exportPath build/export   # -> .ipa
```
An unsigned archive is **not** an installable IPA — Apple requires signing for device installation, and this project doesn't pretend otherwise. The GitHub Actions workflow builds/tests unsigned on a macOS runner and produces a signed IPA only when you configure the signing secrets (`BUILD_CERTIFICATE_BASE64`, `P12_PASSWORD`, App Store Connect API keys).

## 3. Use it

1. In the app: Settings → set Backend URL + App API key → turn on upload consent (only if you accept sending *extracted text* to your backend).
2. iOS Settings → General → Keyboard → add **Relationship AI Keyboard**, allow Full Access for suggestions (see the in-app explanation).
3. Scan: keyboard → **Scan Chat** → consent → system broadcast picker → open your messaging app → scroll the chat slowly → stop the broadcast.
4. Back in the app: review the scanned messages and uncertainty notes → **Generate Replies**.
5. Switch to the messaging app, pick the keyboard: your 3 suggestions are in the bar. Tap to insert, edit if you like, and send it yourself.

### Recent chat — screenshot → suggestions (new in 1.7.0)

For a chat that just arrived, you don't need the broadcast scan or browsing for photos:

1. A new message comes in your chat app — take a screenshot of it.
2. Open Relationship AI → **Recent chat: use latest screenshot**.
3. Tap **Use latest screenshot → Generate replies**.

That one tap reads only your latest screenshot from Photos, runs the same on-device Vision OCR, **replaces the old suggestions** (so the keyboard never keeps showing the previous chat's replies), and — if consent is ON — generates the 3 new replies immediately. If you tap again without a new screenshot, it tells you that screenshot was already used instead of giving you the same suggestions again.

Honest limit: iOS does not let any app watch another app's chats or screenshot another app by itself, so step 1 — you taking the screenshot — can't be automated. The app also can't know a new chat arrived on its own; you open it after screenshotting. For a longer chat, use **Import Chat → Choose screenshots** and pick several in order, as before.

### Screenshot Adjustor — more accurate replies (new in 1.8.0)

A full screenshot often makes replies *less* accurate: the status bar, chat header, keyboard, or another chat in the picture leak stray words in, and old messages at the top pull the reply back to an old topic. The Adjustor fixes that before generation:

1. Take a screenshot of the recent chat, as in 1.7.0.
2. In **Import Chat → Recent chat**, tap **Adjust screenshot → More accurate replies**.
3. Trim the top (status bar / header) and bottom (keyboard / composer) with the sliders — the preview shows exactly what will be read.
4. Choose **Keep only** — Last 4, Last 6 (default), Last 10, or All messages.
5. Tap **Generate from adjusted screenshot**.

It runs the same on-device OCR, clears the old suggestions first, and generates 3 new replies — just from a cleaner, current context. The screenshot itself never leaves the phone, and the one-tap "Use latest screenshot" button is unchanged for when you don't need to adjust.

### Select a message 📸 — reply to just that message (new in 1.9.0)

For the most accurate reply of all, answer one particular message instead of a whole screenshot:

1. Open the conversation (Instagram, WhatsApp, or Snapchat) and take a screenshot of it.
2. Open Relationship AI → **Import Chat → Recent chat → Select a message 📸**.
3. Your latest screenshot opens in the app. Drag your finger to draw a rectangle around that one message.
4. Tap **Generate replies for this message**.

Only the rectangle is OCR'd on-device — no other message, header, or keyboard can leak in. The sender is judged from where the box sits in the full screenshot (left = them, right = you), the language is detected from that message (Roman Urdu, Roman Telugu, or English), and you get 3 replies in that language. Tap a suggestion in the app to copy it, or switch to the Relationship AI keyboard where the same suggestions are available to insert. It never sends by itself. You can re-open the same screenshot and select a different message — selecting a new rectangle always works, even from the same screenshot.

### From the keyboard: Select 📸 (new in 1.10.0)

The keyboard bar now has a **Select 📸** button next to Scan Chat. The honest limit first: a keyboard extension's view is only the keyboard area — it cannot cover the chat above it, read that chat, or screenshot another app. So the rectangle cannot literally be drawn over Instagram from the keyboard, on any stock iPhone app.

What the keyboard button does, which is the closest iOS allows, is jump you straight there in one tap:

1. In the chat, take a screenshot first (phone buttons) — the keyboard cannot take it for you.
2. On the Relationship AI keyboard, tap **Select 📸**.
3. The main app opens straight to the Select Message screen with your latest screenshot already loaded.
4. Drag the rectangle around that one message, tap Generate, then switch back to Instagram — the 3 suggestions are in the keyboard bar to tap and insert.

Without the button, the same screen is at Home → Import Chat → Recent chat → "Select a message 📸".

### Chat language preference (new in 1.11.0)

Home → "2 · Your inputs" now has a **Chat language** setting: Auto detect, Roman Urdu, Roman Telugu, English, or a mixed option. If detection keeps getting your chat wrong — especially with short messages — set it once to the language you actually chat in, and suggestions always use that language, skipping detection entirely. This applies to normal suggestions and to Ask about this chat.

### Guide — should I message now? (new in 1.12.0)

After a screenshot import or a scan, Home shows a **Guide — should I message now?** section (only when a conversation is loaded). Tap Get Guide — no question to type. It reads only that scanned chat and tells you: **Message now or Wait**, why (who sent last, and any mood signals actually in the chat — or that the mood is not clear), and one concrete next step, plus 3 draft ideas in the chat's language.

Examples of what it does: if you sent last and she has not replied yet, it says Wait and not to double-text; if she sent last, sounds low/tired, or asked a question, it says Message now with one caring, low-pressure draft that offers emotional connection without demanding a reply. It never sends anything by itself, and it never promises to make someone fall in love — it helps build genuine, low-pressure connection and respect her pace.

Accuracy check: before Get Guide, the app shows the last scanned message it will base the guide on, and after the guide it shows how many messages it used. If that last message is not the latest message in the real chat, do not trust the guide — import a new screenshot of the latest chat first, then Get Guide again. A guide that does not answer the last message, match its language, or sound like you should not be sent.

Safety rule: SEND drafts replace the current suggestions and go to the keyboard, like Ask. WAIT drafts stay in the app only as "for later" ideas and are NOT sent to the keyboard, so the keyboard cannot accidentally send a message the guide said to wait on.

### Ask about this chat (new in 1.11.0)

After a screenshot import or a scan, Home shows an **Ask about this chat** section (only when a conversation is loaded). Type a question about that chat — for example, "what does she mean by the last message?" or "how should I reply to this?" — and tap Ask. You get a short answer based only on that scanned chat (if the chat does not contain enough to answer, it says so instead of guessing), plus 3 reply suggestions that follow from the answer. Those suggestions replace the current ones, so they are also available to tap in the app or insert from the keyboard. It never sends anything by itself.

## Privacy

- Explicit consent before scanning and before any upload; both are separate toggles/actions.
- Video/screenshots are never stored or uploaded; OCR runs on-device and only text is kept.
- Retention is configurable (default 24h); **Delete Conversation** wipes context + suggestions from the App Group immediately.
- The Gemini key exists only in the backend environment. The app holds only your backend's URL and its app key.
- Replies are constrained server-side: no invented history, no manipulative/coercive tactics, low-pressure replies when the other person shows disinterest.

## Known limitations

- Sender detection is positional (left = them, right = you — the layout of the supported apps); centred/system lines are marked *unknown* with an uncertainty note rather than guessed silently.
- Group chats: multiple left-side senders are all read as "other" — names in bubbles aren't reliably OCR-attributable.
- OCR quality depends on font size/contrast; low-confidence lines are flagged in the review screen.
