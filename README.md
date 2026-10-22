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
