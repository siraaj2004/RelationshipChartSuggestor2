# Manual acceptance tests (device required — extensions can't be fully verified in CI)

Run on a signed device build. Record pass/fail + iOS version for each.

- [ ] Keyboard appears in WhatsApp, Instagram, Messenger, Telegram (globe-key switch).
- [ ] Keyboard types, backspace/shift/symbols/return work; dark & light mode legible.
- [ ] With no scan: suggestion bar is empty and shows "No scanned chat yet" — no invented suggestions.
- [ ] Scan Chat from keyboard opens the host app scanner screen.
- [ ] Broadcast starts only after tapping the system picker and iOS's Start Broadcast.
- [ ] During broadcast, the iOS red indicator is visible; status in app says Broadcasting.
- [ ] Scrolling a chat, then stopping, populates the scanned conversation in the app.
- [ ] Duplicate messages from overlapping scroll frames appear once.
- [ ] Low-confidence / centre-position lines show uncertainty notes in the app.
- [ ] Roman Telugu, Roman Urdu, English chats are labelled with the right language.
- [ ] Generate Replies (with consent on) returns 3 suggestions that match the chat's language/tone.
- [ ] The 3 suggestions appear in the keyboard bar; tapping one inserts it and does NOT send.
- [ ] With consent off, Generate Replies refuses with the consent error.
- [ ] Stop Scanning + Delete Conversation remove the context; keyboard bar empties.
- [ ] Retention: set retention to a short window, wait, context is gone.
