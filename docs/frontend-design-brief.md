# Clippy — Frontend Design Brief

A copy-paste-ready brief for a design tool. Describes the app and its frontend only.

## What it is
**Clippy is a cross-device clipboard sync app.** Copy text on one device and it
instantly appears on your other devices, ready to paste — end-to-end encrypted,
so nothing readable leaves your devices. A "universal clipboard" for people who
mix a Mac and an Android phone (iPhone/Windows planned). Mascot & app icon: a
friendly **paperclip with eyes** (a nod to the old Office Clippy).

## What it does (user's mental model)
1. **Pair your devices once** — one device makes a secret "group key"; the others
   join it by scanning a QR or pasting the key.
2. **After that, copying just syncs** both ways.
3. **A browsable history** of recent clips lives in the app; tap any past clip to
   drop it back onto your clipboard.
4. Everything is **encrypted**; the server only relays scrambled blobs and never
   sees your text or identity.

## Platforms & shell
- **Android** (phone + tablet) and **macOS desktop** today; one shared UI.
- Single window, no tabs: a top app bar, one flat body, a bottom input bar.

## Screens

### 1. Pairing screen (first launch / not paired)
Centered column, max width ~460px, scrollable.
- Large **paperclip glyph (📎)** in brand purple.
- Title **"Pair your devices"** + explainer paragraph.
- **"Group key"** multi-line text field with a **copy icon** suffix.
- When a key is present: a **QR code** on a white rounded card + caption
  **"Scan this on your other device."**
- Full-width buttons: **"Generate a new key"** (outlined, key icon),
  **"Scan QR code"** (outlined, scanner icon — mobile only),
  **"Pair this device"** (filled, primary).

### 2. QR scanner screen
- Full-bleed **camera viewfinder**, centered **square white frame** target,
  bottom hint **"Point at the QR shown on your other device."**, app bar
  **"Scan pairing QR."**

### 3. Home screen (paired — main screen)
- **App bar** (solid brand purple, white content): title **"📎 Clippy"**;
  right actions: **add another device** (devices icon), **unpair** (logout icon).
- **Status banner** under the app bar:
  - *Synced* (soft lavender): sync icon + "Synced. Incoming clips land on your
    clipboard; add one below to send." (Desktop: "Auto-syncing — anything you
    copy here appears on your other devices.")
  - *Reconnecting* (soft red): cloud-off icon + "Reconnecting…"
- **Clip history list** — the centerpiece. Each clip is a **clean outlined row**
  (10px rounded border, subtle border, surface fill, 8px gaps):
  - **Left:** clip text (medium weight, ≤2 lines, ellipsis) + muted **"Tap to
    copy"** subtitle.
  - **Right:** outlined **copy icon** in the primary color.
  - Tap row or icon → copies to clipboard, shows **"Copied to clipboard"** snackbar.
- **Empty state:** centered muted "Nothing synced yet. Copy something on another
  device, or add one below."
- **Bottom add bar:** text field **"Add a clip to sync…"** + filled **"Send"**.

### 4. Add-device dialog (from app bar)
- AlertDialog **"Add another device"**: "Scan this on your other device, or paste
  the key:", a **QR code** (white card), the key as **selectable monospace**, and
  a **"Copy key"** action.

## States to design
Loading (spinner) · unpaired · paired+synced · paired+reconnecting · empty
history · populated history · snackbars ("Copied to clipboard", "Key copied",
"That does not look like a valid key").

## Visual language / tokens
- **Material 3.**
- **Brand seed:** indigo-purple **`#6C4DF6`**; secondary blue **`#5B8DEF`**.
- **App bar:** primary purple, white text/icons.
- **Cards/rows:** rounded 10–12px, thin outline-variant border, surface fill;
  primary-colored action icons.
- **Status banners:** primary-container (synced) vs error-container (reconnecting).
- **Accent emoji:** 📎 branding; ✅/🎯 sometimes inside clip text.
- **App icon:** rounded-square blue→indigo gradient tile with a subtle lighter
  highlighted panel and a large white **paperclip with two friendly eyes**.
- **Tone:** clean, calm, trustworthy (it handles your clipboard, incl. passwords),
  lightly playful via the mascot.

## One-line summary
A calm, Material-3 "universal clipboard" app: a purple-branded home screen
showing synced clip cards (text left, copy icon right), a top sync-status banner,
a bottom "add a clip" bar, and a first-run pairing screen with a QR code —
friendly paperclip-with-eyes mascot throughout.
