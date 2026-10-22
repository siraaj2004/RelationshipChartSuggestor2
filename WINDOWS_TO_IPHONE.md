# Windows → iPhone: how to get this IPA onto your iPhone

You do **not** need a Mac you own — but the IPA still has to be *built* on macOS
somewhere, and *signed* before iOS will run it. On Windows your job is steps 2–3.

```
[1. Build on macOS cloud]  ->  [2. Download .ipa on Windows]  ->  [3. Sign + install from Windows]
     GitHub Actions (free)          github.com artifact            Sideloadly or AltStore
```

Windows alone cannot: run Xcode, compile an iOS app, or install an unsigned IPA
(iTunes / the Apple Devices app only install App Store–signed apps).

---

## Step 1 — Build the IPA (from your Windows browser, ~10 min)

1. Create a free GitHub account, create a new **private** repository, and upload
   the contents of this project folder to it (GitHub web upload works).
2. In the repo: **Actions → “Unsigned IPA for Windows sideloading” → Run workflow**.
3. When it finishes green, open the run → **Artifacts → RelationshipAIKeyboard-unsigned-ipa**
   → download and unzip it on Windows. You now have `RelationshipAIKeyboard-unsigned.ipa`.

*Alternative:* rent a cloud Mac (e.g. MacinCloud, MacStadium) and run
`bash scripts/package-unsigned-ipa.sh` there — same file.

## Step 2 — Connect the iPhone to Windows (first time = USB cable, not Wi-Fi)

1. Install **Apple Devices** (Microsoft Store) — or iTunes — on Windows so the
   iPhone drivers are present, and open it once.
2. Plug the iPhone in with a Lightning / USB-C cable, unlock it, and tap
   **Trust This Computer** (enter your passcode). The iPhone should appear in
   Apple Devices / iTunes. If it doesn't: try another cable/port, unlock again —
   Wi-Fi sync cannot be set up until this USB pairing has happened once.
3. On the iPhone (iOS 16+): **Settings → Privacy & Security → Developer Mode → On**
   (the phone will restart). Sideloaded apps won't open without this.

## Step 3A — Install with Sideloadly (simplest, recommended)

1. Download Sideloadly for Windows from **sideloadly.io** (official site only).
2. Open Sideloadly — your iPhone should show in the device dropdown (keep it cabled).
3. Drag `RelationshipAIKeyboard-unsigned.ipa` into Sideloadly, enter **your Apple ID**
   (use a spare Apple ID if you prefer — it is only used to request a personal
   signing certificate from Apple), click **Start**.
   Never enter your Apple ID into any other IPA/installer website or tool.
4. On the iPhone: **Settings → General → VPN & Device Management → your Apple ID →
   Trust**, then open the app.

## Step 3B — Or install with AltStore

1. Install **iTunes and iCloud from Apple's website** (not the Microsoft Store
   versions — AltServer needs the Apple ones), then install **AltServer** for
   Windows from **altstore.io**.
2. Cable the iPhone, run AltServer → system tray icon → **Install AltStore → your iPhone**.
3. Open AltStore on the phone, sign in, then **My Apps → + →** pick the `.ipa`
   (put it in Files/iCloud Drive or transfer it to the phone first).
4. Keep AltServer running on the PC on the same Wi-Fi so AltStore can refresh
   the app before it expires.

---

## The honest limits — especially for THIS app

| Route | Cost | App expiry | Keyboard + Broadcast extensions |
|---|---|---|---|
| Free Apple ID (Sideloadly/AltStore) | Free | **7 days**, then re-sign/re-install from Windows | ⚠️ **Unreliable — see below** |
| Apple Developer Program | $99/year | 1 year, TestFlight or direct install | ✅ Proper route |
| Cloud Mac only | Rental | — (build only, still needs signing above) | — |

Why the warning: this is not a single simple app. It is **3 signed pieces**
(main app + keyboard extension + broadcast extension) that share data through
an **App Group**. Free personal certificates:
- get at most 3 sideloaded apps and a limited number of App IDs per week,
- often have App Group entitlements stripped or mismatched during re-signing —
  which silently breaks the sharing between the scanner, the app and the keyboard
  (the app opens, but suggestions never reach the keyboard),
- and everything expires in 7 days.

So: use Sideloadly to **try the app shell and the UI**, but for the keyboard to
actually work day-to-day, the reliable path is the **Apple Developer Program
($99/year)** — build with the existing signed workflow
(`.github/workflows/build.yml`), distribute via **TestFlight**, and then no
cable or Windows tool is involved at all: the phone installs it from TestFlight
directly, extensions and App Group included.

## Troubleshooting

- **“Untrusted Developer”** — Step 3A.4 trust step, then reopen the app.
- **App opens then closes instantly** — Developer Mode is off, or the 7-day
  certificate expired: re-run Sideloadly with the phone cabled.
- **iPhone not detected on Windows** — Apple Devices/iTunes not installed,
  phone locked, or cable is charge-only. Unlock + Trust again.
- **Keyboard not in Settings → Keyboards** — the extension failed to sign
  (free-cert limit above); check Sideloadly's log for the keyboard appex error.
- **Keyboard present but no suggestions** — expected until a chat is scanned and
  replies are generated; with free signing it can also mean the App Group was
  stripped — that needs the paid-developer/TestFlight route.
