# Smart ToolBox — Fab Academy Documentation

**Student:** Layer6
**Project:** RFID Smart Tool Tracking System
**Last Updated:** 2026-05-09

---

## Table of Contents

1. [Project Summary](#1-project-summary)
2. [System Overview](#2-system-overview)
3. [Week 1 — Hardware & Firmware](#3-week-1--hardware--firmware)
4. [Week 2 — Cloud & Firebase Setup](#4-week-2--cloud--firebase-setup)
5. [Week 3 — Flutter Mobile App](#5-week-3--flutter-mobile-app)
6. [Week 4 — PWA Deployment (No iPhone Developer Account)](#6-week-4--pwa-deployment-no-iphone-developer-account)
7. [Week 5 — Fixing ESP32 Live Status on PWA](#7-week-5--fixing-esp32-live-status-on-pwa)
8. [Week 6 — Native iOS Sideload via AltStore (No $99 Account)](#8-week-6--native-ios-sideload-via-altstore-no-99-account)
9. [Full Code Reference](#9-full-code-reference)
10. [All Prompts Used](#10-all-prompts-used)
11. [What I Learned](#11-what-i-learned)
12. [Files & Downloads](#12-files--downloads)
13. [Troubleshooting Log](#13-troubleshooting-log)

---

## 1. Project Summary

For my Fab Academy final project I built a **Smart ToolBox** — a physical drawer system that tracks who takes and returns tools using RFID cards, physical buttons on each tool slot, and a solenoid lock. Everything is connected to a cloud database so I can see the real-time status of every tool from my phone anywhere in the world.

**The problem I was solving:** In a shared lab, tools go missing. Nobody knows who took what or when. I wanted a system that logs every tool interaction, locks the drawer so only authorized users can open it, and shows a live dashboard on my phone.

**What I built:**
- An ESP32-S3 microcontroller with RC522 RFID reader, solenoid lock, reed switch, and 4 tool-presence buttons
- Firmware in C++ (Arduino framework, PlatformIO) that handles RFID auth, tool tracking, and cloud sync
- A local web admin panel served from the ESP32 for managing RFID users
- Firebase Firestore for cloud storage
- A Flutter app deployed as a PWA (Progressive Web App) to Firebase Hosting — accessible from my iPhone without needing an Apple Developer account ($99/year) or a Mac

**Live URL:** `https://smart-toolbox-b0455.web.app`

---

## 2. System Overview

### Architecture Diagram

```
┌──────────────────────────────────────────────────────────┐
│                  ESP32-S3 (Seeed XIAO)                   │
│                                                          │
│  [RC522 RFID] ──► scan card ──► lookup user in NVM      │
│                        │                                 │
│                  authorized?                             │
│                   YES ──► open solenoid (10s)            │
│                   NO  ──► deny + log                     │
│                                                          │
│  [Tool buttons ×4] ──► detect taken / returned           │
│  [Reed switch]     ──► detect drawer open / closed       │
│  [Web server]      ──► local admin panel (HTTP)          │
│                                                          │
│  On any state change:                                    │
│    ├── POST  → Firestore tool_logs  (event record)       │
│    └── PATCH → Firestore live_status/current (live doc)  │
│                                                          │
│  Every 30 seconds:                                       │
│    └── PATCH → Firestore live_status/current (heartbeat) │
└─────────────────────────┬────────────────────────────────┘
                          │ HTTPS outbound
                          ▼
          ┌───────────────────────────────┐
          │     Google Firebase           │
          │                               │
          │  Firestore                    │
          │   ├── tool_logs/  (history)   │
          │   └── live_status/current     │
          │                               │
          │  Hosting                      │
          │   └── smart-toolbox-b0455     │
          │        .web.app  (PWA)        │
          └──────────────┬────────────────┘
                         │ HTTPS (Firestore SDK)
                         ▼
          ┌───────────────────────────────┐
          │    Flutter PWA on iPhone      │
          │                               │
          │  Box tab  ── live tool status │
          │  Activity ── event history    │
          │  Members  ── RFID user list   │
          │  Settings ── ESP32 IP config  │
          └───────────────────────────────┘
```

### Technology Stack

| Layer | Technology | Why |
|-------|-----------|-----|
| Microcontroller | Seeed XIAO ESP32-S3 | Compact, WiFi built in, 8MB flash |
| Firmware | C++ / Arduino / PlatformIO | Industry standard for embedded |
| RFID | RC522 via SPI | Reliable, cheap, widely documented |
| Cloud DB | Firebase Firestore | Free tier, real-time sync, no server needed |
| App | Flutter (Dart) | Single codebase, compiles to web/Android/iOS |
| Hosting | Firebase Hosting | Free HTTPS hosting, global CDN |
| App format | PWA | No App Store needed, installs on iPhone home screen |

---

## 3. Week 1 — Hardware & Firmware

### What I Did

I started by wiring up the hardware and writing the firmware. The ESP32-S3 is the brain — it reads RFID cards, controls the solenoid lock, monitors tool buttons, and runs a local web server.

### Hardware Wiring

| ESP32 Pin | Connected To | Logic |
|-----------|-------------|-------|
| D8 | RC522 SCK | SPI clock |
| D9 | RC522 MISO | SPI data in |
| D10 | RC522 MOSI | SPI data out |
| D3 | RC522 SS | SPI chip select |
| D1 | RC522 RST | Reset |
| D7 | Solenoid (via relay/MOSFET) | HIGH = unlock |
| D6 | Reed switch (drawer) | INPUT_PULLUP, LOW = closed |
| D0 | Caliper button | INPUT_PULLUP, LOW = taken |
| D2 | Plier button | INPUT_PULLUP, LOW = taken |
| D4 | Micrometer button | INPUT_PULLUP, LOW = taken |
| D5 | Tweezer button | INPUT_PULLUP, LOW = taken |

**Wiring logic:** All tool buttons use `INPUT_PULLUP`. When a tool is physically present in its slot, it presses the button down (LOW). When removed, the button is released (HIGH). I inverted this logic: `LOW = present = false`, `HIGH = absent = true (taken)`.

The drawer reed switch works opposite: a magnet on the drawer keeps it LOW (closed). When the drawer opens, the magnet moves away → HIGH (open).

### Firmware Structure

The firmware (`tool box test/src/main.cpp`) is a single file with these main sections:

```
1. Pin definitions and constants
2. Global state variables (toolCaliper, toolPlier, etc.)
3. Helpers: webLog(), getTimestamp(), uidToString()
4. User management: getAuthorizedName(), saveUser(), deleteUser()
5. Firestore: logToFirestore(), pushLiveStatus()
6. Web server routes: handleRoot(), handleApiTools(), etc.
7. setup(): init pins, SPI, RFID, WiFi, web server routes
8. loop(): handle clients, RFID scan, button debounce, state changes
```

### Key Firmware Code

**RFID auth flow:**
```cpp
if (rfid.PICC_IsNewCardPresent() && rfid.PICC_ReadCardSerial()) {
  String uid = uidToString(rfid.uid.uidByte, rfid.uid.size);
  lastScannedUID = uid;

  String name = getAuthorizedName(uid);
  if (name.length() > 0) {
    currentUserName = name;
    currentUserUID  = uid;
    openSolenoid();           // unlock drawer
  } else {
    webLog("[ACCESS] DENIED → Unknown UID: " + uid);
  }

  rfid.PICC_HaltA();
  rfid.PCD_StopCrypto1();
}
```

**Tool state detection (caliper example):**
```cpp
bool calNow = readDebounced(btns[0]);   // read with 50ms debounce
if (calNow != toolCaliper) {
  toolCaliper = calNow;
  pushLiveStatus();                      // update Firestore live doc

  if (toolCaliper && currentUserName.length() > 0) {
    String ts = getTimestamp();
    logToFirestore(currentUserName, currentUserUID,
                   "Drawer 1", "Caliper", ts, "taken");
  } else if (!toolCaliper) {
    String ts = getTimestamp();
    if (currentUserName.length() > 0)
      logToFirestore(currentUserName, currentUserUID,
                     "Drawer 1", "Caliper", ts, "returned");
  }
}
```

**Button debounce:**
```cpp
#define DEBOUNCE_MS 50

struct DebouncedButton {
  uint8_t pin;
  bool state;
  bool lastRaw;
  unsigned long lastChange;
};

bool readDebounced(DebouncedButton &btn) {
  bool raw = (digitalRead(btn.pin) == LOW);
  if (raw != btn.lastRaw) {
    btn.lastRaw = raw;
    btn.lastChange = millis();
  }
  if ((millis() - btn.lastChange) > DEBOUNCE_MS) {
    btn.state = raw;
  }
  return btn.state;
}
```

### What Went Wrong

- **Python version issue:** PlatformIO CLI (`pio run`) crashed because my system Python is 3.14 and PlatformIO requires 3.10–3.13. Fix: always use the VS Code PlatformIO extension to build and upload, never the terminal.
- **Button logic inversion:** I initially had the tool status backwards (thought LOW = taken, but with pullup it's the opposite). Fixed by carefully reading the pullup behavior.

### How to Build & Upload Firmware

> **IMPORTANT: Do NOT use `pio run` in the terminal.** Use VS Code only.

1. Open `tool box test/` folder in VS Code
2. Click the PlatformIO ant icon in the left sidebar
3. Click **Upload**
4. Watch Serial Monitor for boot messages

### Dependencies (`platformio.ini`)
```ini
[env:seeed_xiao_esp32s3]
platform = espressif32
board = seeed_xiao_esp32s3
framework = arduino
lib_deps =
    mguelbalboa/MFRC522@^1.4.12
    ArduinoJson@^6.18.5
    tzapu/WiFiManager@^2.0.17
```

### WiFi Setup

The firmware uses **WiFiManager** which handles all WiFi credential management:

1. On boot: tries saved credentials
2. If none → opens AP hotspot **"ToolBox by Layer6"** (password: `setup1234`)
3. Connect your phone/PC to that hotspot
4. Browse to `http://192.168.4.1` → configure WiFi
5. Device restarts and connects to your network
6. To reset WiFi: Admin panel → WiFi section → Reset WiFi button

### Local Admin Panel

Once on WiFi, the ESP32 serves a web admin panel:
- **URL:** `http://[device-ip]` or `http://toolbox.local`
- **Login:** `admin` / `admin123`
- **Features:** real-time serial log, RFID user management, WiFi config, live tool status

---

## 4. Week 2 — Cloud & Firebase Setup

### What I Did

I set up Firebase to store all the tool events in the cloud. I used the Firestore REST API from the ESP32 (no SDK — the ESP32 just makes HTTP POST requests) and the Firestore Flutter SDK from the app.

### Firebase Project

- **Project ID:** `smart-toolbox-b0455`
- **Console:** `https://console.firebase.google.com/project/smart-toolbox-b0455`
- **API Key (public):** `AIzaSyCYQFnhupq9GiL7P0D5VeIftWvh3ePTKSs`

### Firestore Collections

**`tool_logs`** — one document per tool event:
```json
{
  "userName":  "James May",
  "uid":       "AA BB CC DD",
  "drawer":    "Drawer 1",
  "tool":      "Caliper",
  "timestamp": "14:32:10-09-05-2026",
  "action":    "taken",
  "epochMs":   "1746789130000"
}
```
> `epochMs` is Unix milliseconds as a string. Used for client-side sorting (newest first) in Flutter.

**`live_status/current`** — single document, overwritten on every state change:
```json
{
  "caliper":    false,
  "plier":      true,
  "micrometer": false,
  "tweezer":    false,
  "drawer1":    false,
  "updatedAt":  "14:32:10-09-05-2026",
  "epochMs":    "1746789130000"
}
```
> This document was added in Week 5 to fix the PWA live status problem. See [Week 5](#7-week-5--fixing-esp32-live-status-on-pwa).

### How the ESP32 Writes to Firestore

The ESP32 uses the Firestore REST API directly over HTTPS. No Firebase SDK is needed on the device.

**Sending a tool event (POST):**
```cpp
void logToFirestore(String userName, String uid, String drawer,
                    String tool, String timestamp, String action) {
  if (WiFi.status() != WL_CONNECTED) return;

  HTTPClient http;
  String url = firestoreBase + "?key=" + FIREBASE_API_KEY;
  http.begin(url);
  http.addHeader("Content-Type", "application/json");

  StaticJsonDocument<512> doc;
  JsonObject fields = doc.createNestedObject("fields");
  fields["userName"]["stringValue"]  = userName;
  fields["uid"]["stringValue"]       = uid;
  fields["drawer"]["stringValue"]    = drawer;
  fields["tool"]["stringValue"]      = tool;
  fields["timestamp"]["stringValue"] = timestamp;
  fields["action"]["stringValue"]    = action;

  struct tm timeinfo;
  if (getLocalTime(&timeinfo)) {
    fields["epochMs"]["integerValue"] =
        String((long long)mktime(&timeinfo) * 1000LL);
  }

  String body;
  serializeJson(doc, body);
  int code = http.POST(body);
  http.end();
}
```

The URL format for Firestore REST API:
```
POST https://firestore.googleapis.com/v1/projects/{PROJECT_ID}/databases/(default)/documents/{COLLECTION}?key={API_KEY}
```

### NTP Time Sync

The ESP32 syncs its clock from the internet on boot so timestamps are accurate:
```cpp
configTime(19800, 0, "pool.ntp.org");  // IST = UTC+5:30 = 19800 seconds offset
```

### Firestore Security Rules

Currently open for development. Tighten before going public:
```javascript
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /{document=**} {
      allow read, write: if true;   // lock this down for production
    }
  }
}
```

### FlutterFire CLI Setup (one-time, already done)

To generate `firebase_options.dart` for the Flutter app:
```bash
dart pub global activate flutterfire_cli
flutterfire configure --project=smart-toolbox-b0455
```
This creates `lib/firebase_options.dart` with platform-specific app IDs. Already committed — no need to run again.

---

## 5. Week 3 — Flutter Mobile App

### What I Did

I built the Flutter app that monitors the toolbox. Everything is in a single file (`lib/main.dart`) for simplicity. The app has 4 tabs: Box, Activity, Members, Settings.

### App Info

| Field | Value |
|-------|-------|
| App name | ToolTrack |
| Bundle ID | `com.layer6.tooltrack` |
| Android package | `com.layer6.tooltrack` |
| Flutter channel | stable |
| Min Android SDK | 21 (Android 5.0) |

### Dependencies (`pubspec.yaml`)

```yaml
dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.8
  firebase_core: ^4.7.0
  cloud_firestore: ^6.3.0
  http: ^1.2.2
  shared_preferences: ^2.3.2
```

> I removed `firebase_storage` and `image_picker` — they were listed in pubspec but never imported in code. They also broke `flutter build web` because their web plugin registrants referenced packages that weren't resolvable after removal.

### Screens

**Box tab (`BoxScreen`)** — main screen, shows all 4 tools with live status:
- Streams `live_status/current` from Firestore (real-time, works over HTTPS)
- Also polls ESP32 `/api/tools` every 10s as a local fallback
- Shows each tool as a card: Present / Checked Out / Missing
- Device chip shows: `Local` (ESP32 reachable) / `Cloud` (Firestore data) / `Off`

**Activity tab (`ActivityScreen`)** — full event history:
- Streams `tool_logs` collection from Firestore
- Filter chips: All / Taken / Returned
- Sorted by `epochMs` (newest first, client-side)

**Members tab (`MembersScreen`)** — list of authorized RFID users:
- Calls ESP32 `/api/users` over local HTTP
- Only works when phone and ESP32 are on the same WiFi
- Shows each user's name, UID, and how many tools they currently have out

**Settings tab (`SettingsScreen`)** — configure ESP32 IP:
- Saves IP to `SharedPreferences` (persists across app restarts)
- Default IP: `192.168.4.1` (ESP32 AP mode)

### Color Theme

```dart
class C {
  static const bg         = Color(0xFFF5F0E8);  // warm off-white
  static const bgDeep     = Color(0xFFEDE6D9);  // deeper background
  static const card       = Colors.white;
  static const ink        = Color(0xFF1C1917);  // primary text
  static const ink2       = Color(0xFF57534E);  // secondary text
  static const ink3       = Color(0xFFA8A29E);  // muted/hint text
  static const orange     = Color(0xFFE8772E);  // primary accent
  static const orangeDk   = Color(0xFFC2410C);  // dark accent
  static const present    = Color(0xFF22C55E);  // tool in box (green)
  static const checkedOut = Color(0xFFF97316);  // tool out (orange)
  static const missing    = Color(0xFFEF4444);  // missing (red)
}
```

### Firestore Real-time Streaming (Flutter)

The app uses `StreamBuilder` to listen to Firestore in real time — no manual refresh needed:

```dart
StreamBuilder<QuerySnapshot>(
  stream: FirebaseFirestore.instance
      .collection('tool_logs')
      .limit(200)
      .snapshots(),
  builder: (ctx, snap) {
    if (!snap.hasData) return CircularProgressIndicator();

    var logs = snap.data!.docs.map(ToolLog.fromFirestore).toList();
    logs.sort((a, b) => b.createdAt!.compareTo(a.createdAt!)); // newest first

    return ListView.builder(
      itemCount: logs.length,
      itemBuilder: (_, i) => _ActivityTile(log: logs[i]),
    );
  },
)
```

### Tool Log Model

```dart
class ToolLog {
  final String id, userName, uid, drawer, tool, timestamp, action;
  final DateTime? createdAt;

  bool get isTaken => action != 'returned';

  factory ToolLog.fromFirestore(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>? ?? {};
    DateTime? createdAt;
    final epochMs = d['epochMs'];
    if (epochMs != null) {
      final ms = int.tryParse(epochMs.toString());
      if (ms != null) createdAt = DateTime.fromMillisecondsSinceEpoch(ms);
    }
    return ToolLog(
      id: doc.id,
      userName:  d['userName']  ?? '',
      uid:       d['uid']       ?? '',
      drawer:    d['drawer']    ?? '',
      tool:      d['tool']      ?? '',
      timestamp: d['timestamp'] ?? '',
      action:    d['action']    ?? 'taken',
      createdAt: createdAt,
    );
  }
}
```

### What Went Wrong

- **Bundle ID mismatch:** `CLAUDE.md` said the package was `com.layer6.toolbox` but actual Xcode and Firebase configs all said `com.layer6.tooltrack`. Fixed the documentation.
- **Unused packages:** `firebase_storage` and `image_picker` were in `pubspec.yaml` but not imported. They silently passed `flutter pub get` but crashed `flutter build web` because the auto-generated plugin registrant tried to import their web implementations. Fix: remove both from pubspec, then `flutter clean && flutter pub get`.

---

## 6. Week 4 — PWA Deployment (No iPhone Developer Account)

### The Problem I Had

I wanted to test the app on my iPhone. My options were:
- **App Store / TestFlight:** Requires $99/year Apple Developer Program, Mac, Xcode, certificates — I have none of these
- **USB sideload:** Requires Mac and Xcode
- **Android:** I only have an iPhone

### The Solution: PWA (Progressive Web App)

Flutter can build a web version of the app. When hosted on HTTPS, it can be installed on an iPhone home screen and opens full-screen like a native app. No App Store. No Mac. No $99.

My app is perfect for this — it only uses Firestore (HTTPS) and HTTP calls to the ESP32 (local network). No camera, Bluetooth, or native sensors needed.

### Firebase Web Config

The `firebase_options.dart` already had a web config because I ran `flutterfire configure` earlier with web platform selected:

```dart
static const FirebaseOptions web = FirebaseOptions(
  apiKey:            'AIzaSyCYQFnhupq9GiL7P0D5VeIftWvh3ePTKSs',
  appId:             '1:471683042983:web:c96bd7eda706898337d582',
  messagingSenderId: '471683042983',
  projectId:         'smart-toolbox-b0455',
  authDomain:        'smart-toolbox-b0455.firebaseapp.com',
  storageBucket:     'smart-toolbox-b0455.firebasestorage.app',
  measurementId:     'G-SFYV8RW1NC',
);
```

### PWA Manifest (`web/manifest.json`)

Updated from Flutter defaults to match the app:
```json
{
  "name": "ToolTrack",
  "short_name": "ToolTrack",
  "start_url": ".",
  "display": "standalone",
  "background_color": "#0A0A0F",
  "theme_color": "#0A0A0F",
  "description": "Smart ToolBox monitor — track tool checkouts in real time.",
  "orientation": "portrait-primary",
  "prefer_related_applications": false,
  "icons": [
    { "src": "icons/Icon-192.png", "sizes": "192x192", "type": "image/png" },
    { "src": "icons/Icon-512.png", "sizes": "512x512", "type": "image/png" },
    { "src": "icons/Icon-maskable-192.png", "sizes": "192x192",
      "type": "image/png", "purpose": "maskable" },
    { "src": "icons/Icon-maskable-512.png", "sizes": "512x512",
      "type": "image/png", "purpose": "maskable" }
  ]
}
```

### iOS PWA Meta Tags (`web/index.html`)

Added to make the install experience clean on iPhone:
```html
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="ToolTrack">
<meta name="theme-color" content="#0A0A0F">
<link rel="apple-touch-icon" href="icons/Icon-192.png">
<style>
  body { background-color: #0A0A0F; margin: 0; }
</style>
```

### Firebase Hosting Config (`firebase.json`)

```json
{
  "hosting": {
    "public": "build/web",
    "ignore": ["firebase.json", "**/.*", "**/node_modules/**"],
    "rewrites": [{ "source": "**", "destination": "/index.html" }],
    "headers": [
      {
        "source": "**/*.@(js|css|wasm)",
        "headers": [{ "key": "Cache-Control", "value": "max-age=31536000" }]
      },
      {
        "source": "index.html",
        "headers": [{ "key": "Cache-Control", "value": "no-cache" }]
      }
    ]
  }
}
```

> The `rewrites` rule sends all URL paths to `index.html`. This is required for Flutter web's client-side router.
> JS/CSS/WASM files are cached for 1 year (they have content-hashed filenames). `index.html` is never cached so updates are instant.

### `.firebaserc`

```json
{
  "projects": {
    "default": "smart-toolbox-b0455"
  }
}
```

### Build & Deploy Process

```bash
# 1. Remove unused packages that break web build
# (already done — firebase_storage and image_picker removed from pubspec.yaml)

# 2. Clean any stale build cache
flutter clean
flutter pub get

# 3. Build the web release
cd "MOBILE APP/toolbox_app"
flutter build web --release

# 4. Deploy to Firebase Hosting
firebase deploy --only hosting
```

Build output goes to `build/web/`. The `firebase deploy` command uploads those files.

**Build time:** ~45 seconds on my machine.

**Deploy time:** ~15 seconds (only changed files are uploaded).

### Installing on iPhone

1. Open **Chrome** or **Safari** on iPhone
2. Go to `https://smart-toolbox-b0455.web.app`
3. Tap the **Share button** (square with arrow up)
4. Tap **"Add to Home Screen"**
5. Name it `ToolTrack` → tap **Add**

Opens full-screen, no browser chrome, dark background while loading. Looks native.

### What Went Wrong

- **Build crash from stale .dart_tool:** After removing packages from pubspec, the auto-generated `.dart_tool/flutter_build/.../web_plugin_registrant.dart` still had `import` statements for the removed packages. Running `flutter clean` deleted `.dart_tool` entirely and the regenerated file was correct.
- **firebase.json conflict:** The `firebase.json` file already existed (created by FlutterFire CLI with the `flutter` key). I had to merge my `hosting` config into it rather than replacing it, to avoid breaking the FlutterFire config.

---

## 7. Week 5 — Fixing ESP32 Live Status on PWA

### The Problem

After deploying the PWA, I noticed the **Box tab showed no live tool status** even though the ESP32 was running and the Activity log (from Firestore) was working fine.

The root cause: **Mixed content policy.**

The PWA is served over `https://smart-toolbox-b0455.web.app`. The ESP32 web server runs over plain `http://192.168.x.x`. All modern iOS browsers — Safari, Chrome, Firefox — block HTTP requests from HTTPS pages. This is a browser security rule, not something I can turn off.

The original Flutter code polled the ESP32 every 10 seconds:
```dart
// This is BLOCKED on iPhone when the PWA is on HTTPS
final r = await http.get(
  Uri.parse('http://$ip:$port/api/tools'),
  headers: {'Cookie': 'auth=1'},
).timeout(const Duration(seconds: 5));
```

The call silently fails. No error shown, just no data.

### What I Considered (And Why I Rejected It)

| Option | Why it doesn't work |
|--------|-------------------|
| Add HTTPS to ESP32 | Self-signed certs are rejected by iOS Safari in PWA mode |
| Let's Encrypt cert on ESP32 | Can't get public CA cert for a local IP address |
| Firebase Cloud Function proxy | Cloud Functions can't reach local ESP32 — it's not on the internet |
| Serve PWA from ESP32 over HTTP | Flutter web build is ~3MB; complex to serve from embedded device; ESP32 storage would be tight |
| Use Chrome instead of Safari | Chrome on iOS is also WebKit — same restriction applies |

### The Solution

The ESP32 already pushes data to Firestore over HTTPS (for tool event logs). I extended this to also push the **current live status** to a dedicated Firestore document (`live_status/current`) on every state change. The Flutter app then subscribes to this document via the Firestore SDK — all over HTTPS, no mixed content issue.

```
Before fix:
  Flutter PWA ──[HTTP blocked]──✕── ESP32

After fix:
  ESP32 ──[HTTPS]──► Firestore live_status/current ──[HTTPS]──► Flutter PWA
```

### Changes Made to ESP32 Firmware (`main.cpp`)

**1. Added Firestore URL for the live status document:**
```cpp
// After existing firestoreBase definition:
String firestoreLiveUrl =
    "https://firestore.googleapis.com/v1/projects/"
    FIREBASE_PROJECT_ID
    "/databases/(default)/documents/live_status/current";
```

**2. Added timing globals:**
```cpp
unsigned long lastLivePush = 0;
#define LIVE_PUSH_INTERVAL 30000  // 30s heartbeat
```

**3. Added `pushLiveStatus()` function** (added before `openSolenoid()`):
```cpp
void pushLiveStatus() {
  if (WiFi.status() != WL_CONNECTED) return;

  HTTPClient http;
  String url = firestoreLiveUrl + "?key=" + FIREBASE_API_KEY;
  http.begin(url);
  http.addHeader("Content-Type", "application/json");

  StaticJsonDocument<512> doc;
  JsonObject fields = doc.createNestedObject("fields");
  fields["caliper"]["booleanValue"]    = toolCaliper;
  fields["plier"]["booleanValue"]      = toolPlier;
  fields["micrometer"]["booleanValue"] = toolMicrometer;
  fields["tweezer"]["booleanValue"]    = toolTweezer;
  fields["drawer1"]["booleanValue"]    = drawerOpen;
  fields["updatedAt"]["stringValue"]   = getTimestamp();

  struct tm timeinfo;
  if (getLocalTime(&timeinfo)) {
    fields["epochMs"]["integerValue"] =
        String((long long)mktime(&timeinfo) * 1000LL);
  }

  String body;
  serializeJson(doc, body);

  // PATCH creates or overwrites the document — not append like POST
  int code = http.sendRequest("PATCH", body);
  if (code == 200) {
    webLog("[FIRESTORE] ✓ Live status pushed");
  } else {
    webLog("[FIRESTORE] ✗ Live status failed: HTTP " + String(code));
  }
  http.end();
  lastLivePush = millis();
}
```

**Why PATCH and not POST?**
- `POST` to a Firestore collection creates a **new document** each time (append)
- `PATCH` to a specific document path **creates or updates** that single document
- I want one document that gets overwritten, not thousands of append documents

**4. Added calls in `loop()`:**

Heartbeat timer (added right after `server.handleClient()`):
```cpp
// Push live status to Firestore every 30s
if (millis() - lastLivePush > LIVE_PUSH_INTERVAL) {
  pushLiveStatus();
}
```

After each tool state change (example for caliper):
```cpp
bool calNow = readDebounced(btns[0]);
if (calNow != toolCaliper) {
  toolCaliper = calNow;
  pushLiveStatus();   // ← added here, before logToFirestore()

  if (toolCaliper && currentUserName.length() > 0) {
    // ... logToFirestore(... "taken")
  } else if (!toolCaliper) {
    // ... logToFirestore(... "returned")
  }
}
```

Same `pushLiveStatus()` call added after plier, micrometer, tweezer, and drawer state changes.

### Changes Made to Flutter App (`lib/main.dart`)

**1. Added state fields to `_BoxScreenState`:**
```dart
Map<String, dynamic>? _firestoreLiveData; // from Firestore live_status/current
StreamSubscription<DocumentSnapshot>? _liveStatusSub;
```

**2. Updated `initState()` to subscribe:**
```dart
@override
void initState() {
  super.initState();
  _pollLive();   // existing ESP32 HTTP poll
  _timer = Timer.periodic(const Duration(seconds: 10), (_) => _pollLive());

  // NEW: subscribe to Firestore live_status — works from HTTPS
  _liveStatusSub = FirebaseFirestore.instance
      .collection('live_status')
      .doc('current')
      .snapshots()
      .listen((snap) {
    if (mounted) {
      setState(() {
        _firestoreLiveData =
            snap.exists ? (snap.data() as Map<String, dynamic>?) : null;
        _deviceOnline = _liveData != null || _firestoreLiveData != null;
      });
    }
  });
}
```

**3. Updated `dispose()` to cancel subscription:**
```dart
@override
void dispose() {
  _timer?.cancel();
  _liveStatusSub?.cancel();   // NEW
  super.dispose();
}
```

**4. Updated `_statusFor()` to use Firestore as fallback:**
```dart
ToolStatus _statusFor(AppTool t, List<ToolLog> logs) {
  final key = t.name.toLowerCase();

  // Priority 1: local ESP32 HTTP (fastest, LAN only)
  if (_liveData != null && _liveData!.containsKey(key)) {
    return _liveData![key] == true
        ? ToolStatus.checkedOut
        : ToolStatus.present;
  }

  // Priority 2: Firestore live_status (works from HTTPS anywhere)
  if (_firestoreLiveData != null && _firestoreLiveData!.containsKey(key)) {
    return _firestoreLiveData![key] == true
        ? ToolStatus.checkedOut
        : ToolStatus.present;
  }

  // Priority 3: latest event from tool_logs history
  final toolLogs = logs
      .where((l) => l.tool.toLowerCase() == key)
      .toList();
  if (toolLogs.isEmpty) return ToolStatus.present;
  return toolLogs.first.isTaken
      ? ToolStatus.checkedOut
      : ToolStatus.present;
}
```

**5. Updated device status chip:**
```dart
_statChip(
  'Device',
  _liveData != null
      ? 'Local'
      : (_firestoreLiveData != null ? 'Cloud' : 'Off'),
  (_liveData != null || _firestoreLiveData != null)
      ? C.present
      : C.ink3,
)
```

### Result

| Situation | Before fix | After fix |
|-----------|-----------|-----------|
| On same WiFi as ESP32 | Live status works (local HTTP) | Live status works (local HTTP, same as before) |
| On iPhone PWA over HTTPS | No live status (blocked) | Live status works (Firestore stream) |
| Off network (mobile data) | No live status | Live status works (Firestore stream) |
| ESP32 offline | No live status | Shows last known state (from Firestore) |

### After the Fix: Re-flash ESP32 + Redeploy PWA

```bash
# Rebuild and redeploy Flutter PWA
cd "MOBILE APP/toolbox_app"
flutter build web --release
firebase deploy --only hosting

# Re-flash ESP32 firmware via VS Code PlatformIO → Upload
```

The first time the ESP32 boots after re-flashing, it pushes live status to Firestore immediately. Open the PWA and the Box tab will show real tool states within seconds.

### Timing of Live Updates

```
Tool button state changes
      │
      ▼ immediately
pushLiveStatus() called
      │ ~200–500ms (WiFi HTTPS round trip)
      ▼
Firestore document updated
      │ <1 second (Firestore push delivery)
      ▼
Flutter StreamBuilder fires
      │ immediate
      ▼
UI updates on screen
```

Total delay from physical tool removal to screen update: **under 2 seconds** in normal conditions.

---

## 8. Full Code Reference

### ESP32 Firmware Constants
```cpp
#define FIREBASE_PROJECT_ID  "smart-toolbox-b0455"
#define FIREBASE_API_KEY     "AIzaSyCYQFnhupq9GiL7P0D5VeIftWvh3ePTKSs"
#define ADMIN_USER           "admin"
#define ADMIN_PASS           "admin123"
#define SOLENOID_TIMEOUT     10000   // 10s auto-lock
#define DEBOUNCE_MS          50      // 50ms debounce
#define LIVE_PUSH_INTERVAL   30000   // 30s heartbeat
```

### ESP32 API Endpoints (local, requires auth cookie)

| Method | Path | Body | Response |
|--------|------|------|----------|
| GET | `/` | — | Admin HTML dashboard |
| GET | `/login` | — | Login HTML |
| GET | `/logout` | — | Redirect to /login |
| POST | `/api/login` | `{user, pass}` | Sets `auth=1` cookie |
| GET | `/api/serial` | — | `{logs: [...], lastUID: "..."}` |
| GET | `/api/users` | — | `{users: [{uid, name}, ...]}` |
| POST | `/api/users/add` | `{uid, name}` | `{ok: true}` |
| POST | `/api/users/delete` | `{uid}` | `{ok: true}` |
| POST | `/api/wifi/reset` | — | Restarts device |
| GET | `/api/tools` | — | `{caliper, plier, micrometer, tweezer, drawer1}` |
| GET | `/api/status` | — | `{ip, ssid, rssi}` |

### Firestore Document Schemas

**`tool_logs/{auto-id}`**
```
userName  : string   — "James May"
uid       : string   — "AA BB CC DD"
drawer    : string   — "Drawer 1"
tool      : string   — "Caliper" | "Plier" | "Micrometer" | "Tweezer"
timestamp : string   — "HH:MM:SS-DD-MM-YYYY" (IST)
action    : string   — "taken" | "returned"
epochMs   : integer  — Unix milliseconds (for Flutter sorting)
```

**`live_status/current`**
```
caliper    : boolean — true = tool is OUT
plier      : boolean — true = tool is OUT
micrometer : boolean — true = tool is OUT
tweezer    : boolean — true = tool is OUT
drawer1    : boolean — true = drawer is OPEN
updatedAt  : string  — last update timestamp (IST)
epochMs    : integer — Unix milliseconds
```

### User Storage (ESP32 NVM)

Users are stored in ESP32 non-volatile memory using the `Preferences` library. Data survives reboots and power cuts.

```
Namespace "users":
  key = UID string (e.g. "AA BB CC DD")
  val = Name string (e.g. "James May")

Namespace "userkeys":
  key = "keys"
  val = pipe-separated UID list (e.g. "AA BB CC|DD EE FF GG")
```

---

## 8. Week 6 — Native iOS Sideload via AltStore (No $99 Account)

### What I Did

After getting the PWA working, I wanted a proper native iOS app experience — full screen, no browser, runs offline. The App Store requires a $99/year Apple Developer account and a Mac. I have neither. The solution is **AltStore sideloading** using a free Apple ID.

### How AltStore Works

AltStore exploits the fact that Apple allows any Apple ID (even free ones) to sign apps for personal development. The limitation is the app certificate expires every **7 days**. AltServer runs on your Windows PC in the background and automatically re-signs the app over WiFi before it expires.

```
Codemagic (free Mac CI) ──► builds unsigned .ipa
                                    │
                           you download it
                                    │
                    AltServer on Windows PC
                    + your free Apple ID
                    ──► signs .ipa for your device
                    ──► installs on iPhone via USB/WiFi
                                    │
                    AltServer auto-resigns every 7 days
                    (iPhone + PC on same WiFi)
```

### Limitations of Free Apple ID Sideloading

| Limitation | Detail |
|-----------|--------|
| App expires every 7 days | AltServer auto-resigns if PC is on same WiFi |
| Max 3 sideloaded apps | Across all sideloaded apps on the device |
| No push notifications | Entitlement not available on free account |
| No iCloud sync | Entitlement not available on free account |
| App tied to one device | Certificate is per-device |

For a personal tool tracker these limitations don't matter at all.

### Why Codemagic Can't Sign With a Free Apple ID

Codemagic uses Apple's official certificate API (App Store Connect API). Free Apple IDs are not enrolled in the Apple Developer Program and cannot use that API. **Codemagic cannot sign with a free Apple ID.**

What Codemagic *can* do is build the app without signing (`--no-codesign`). AltServer then handles signing locally on your Windows PC using Apple's personal team entitlement.

---

### Step 1 — Set Up Codemagic to Build the Unsigned IPA

#### 1a. Push your project to GitHub

Codemagic connects to GitHub/GitLab/Bitbucket to pull source code. If you haven't already:

```bash
cd "C:\Users\nadec\OneDrive\Desktop\VIBE-CODING\MOBILE APP\toolbox_app"
git init
git add .
git commit -m "initial commit"
# create a repo on github.com, then:
git remote add origin https://github.com/YOUR_USERNAME/tooltrack.git
git push -u origin main
```

#### 1b. Connect to Codemagic

1. Go to `https://codemagic.io` → Sign up free with GitHub
2. Click **Add application** → select your repo
3. Choose **Flutter App** → **codemagic.yaml** workflow
4. Codemagic detects `codemagic.yaml` automatically

#### 1c. The `codemagic.yaml` (already created at `toolbox_app/codemagic.yaml`)

```yaml
workflows:
  ios-unsigned-altstore:
    name: iOS Unsigned IPA (AltStore / Free Apple ID)
    max_build_duration: 60
    instance_type: mac_mini_m2   # free tier — 500 min/month

    environment:
      flutter: stable
      xcode: latest
      cocoapods: default

    scripts:
      - name: Get Flutter packages
        script: flutter pub get

      - name: Install CocoaPods dependencies
        script: find . -name "Podfile" -execdir pod install \;

      - name: Build iOS (no code signing)
        script: |
          flutter build ios \
            --release \
            --no-codesign

      - name: Package into unsigned .ipa
        script: |
          APP_PATH="build/ios/Release-iphoneos/Runner.app"
          IPA_DIR="build/ios/ipa"
          mkdir -p "$IPA_DIR/Payload"
          cp -r "$APP_PATH" "$IPA_DIR/Payload/"
          cd "$IPA_DIR"
          zip -r "ToolTrack.ipa" Payload/

    artifacts:
      - build/ios/ipa/ToolTrack.ipa
```

**What each step does:**
- `flutter pub get` — downloads Dart packages
- `pod install` — downloads iOS native dependencies (Firebase SDK etc.)
- `flutter build ios --no-codesign` — compiles the app binary, skips signing
- The packaging script wraps `Runner.app` into the `.ipa` zip structure that AltStore expects: `ToolTrack.ipa → Payload/Runner.app`

#### 1d. Trigger a build and download the IPA

1. Push `codemagic.yaml` to your repo — Codemagic auto-triggers
2. Or click **Start new build** in the Codemagic dashboard
3. Build takes ~10–15 minutes on free tier
4. When done: **Artifacts** tab → download `ToolTrack.ipa`

Free tier gives **500 Mac M1/M2 minutes per month**. Each build uses ~12 minutes.

---

### Step 2 — Install AltServer on Windows

AltServer is the desktop companion that signs and installs apps from your PC.

#### 2a. Install prerequisites

You need both of these from Microsoft Store (free):

1. **Apple Devices** (replaces iTunes on Windows 11)
   - Open Microsoft Store → search "Apple Devices" → Install
   - This installs the Apple USB drivers your PC needs to talk to iPhone

2. **iCloud for Windows**
   - Open Microsoft Store → search "iCloud" → Install
   - Sign in with the **same Apple ID** you will use for sideloading
   - iCloud must be running in the background for AltServer to work

#### 2b. Install AltServer

1. Go to `https://altstore.io` → Download AltServer for Windows
2. Run the installer (`AltInstaller.exe`)
3. Click through the install wizard
4. AltServer appears in your system tray (bottom-right, hidden icons `^`)

---

### Step 3 — Install AltStore on Your iPhone

AltStore is the app on your iPhone that manages sideloaded apps. It is itself sideloaded by AltServer.

1. Connect iPhone to PC via USB cable
2. Unlock iPhone and tap **Trust** if prompted
3. Click the AltServer icon in system tray → **Install AltStore** → select your iPhone
4. Enter your Apple ID email and password when prompted
   - AltServer uses these to generate a signing certificate locally — nothing is sent to Apple's servers beyond normal app signing
5. Wait ~30 seconds
6. On iPhone: **Settings → General → VPN & Device Management**
   - Find your Apple ID under "Developer App"
   - Tap it → **Trust** → **Trust**
7. AltStore app now appears on your home screen — open it to verify

---

### Step 4 — Sideload ToolTrack.ipa

#### Option A — Via AltStore on iPhone (easiest)

1. Transfer `ToolTrack.ipa` to your iPhone (AirDrop, email yourself, iCloud Drive, etc.)
2. On iPhone: find the `.ipa` file in Files app
3. Tap it → Share → **AltStore**
4. AltStore signs and installs it (takes ~30 seconds)
5. App appears on home screen

#### Option B — Via AltServer on Windows PC (most reliable)

1. Make sure iPhone is connected via USB (or on same WiFi with AltServer)
2. Click AltServer system tray icon → **Sideload .ipa**
3. Select `ToolTrack.ipa`
4. Enter Apple ID when prompted (same one used for AltStore install)
5. Wait ~60 seconds — app installs directly

Either way, the first launch requires trust:
- **Settings → General → VPN & Device Management → [your Apple ID] → Trust**

---

### Step 5 — Set Up Auto-Resign (7-Day Renewal)

The app certificate expires every 7 days. AltServer handles renewal automatically.

**Requirements for auto-resign:**
- Windows PC must be **on** and **logged in**
- AltServer must be **running** (check system tray)
- iPhone and PC must be on **same WiFi network**
- iCloud for Windows must be running

**How it works:** AltStore on iPhone checks daily. When the cert has < 5 days left, it contacts AltServer over WiFi and re-signs automatically. No USB cable needed for renewal.

**To verify auto-resign is set up:**
1. Open AltStore on iPhone → **My Apps** tab
2. Each app shows days remaining on its certificate
3. Green = good, Yellow = renewal due soon

**If auto-resign fails** (PC was off, different WiFi):
- Connect iPhone to PC via USB
- AltServer tray → it will prompt to resign
- Or open AltStore on iPhone → tap the app → **Refresh**

---

### Troubleshooting AltStore

**"Could not find AltServer" on iPhone**
- Ensure iCloud for Windows is running (check system tray)
- Ensure Apple Devices app is installed (not iTunes)
- Try USB cable instead of WiFi
- Restart AltServer (tray icon → Quit, then reopen)

**"Maximum number of apps reached"**
- Free Apple ID allows max 3 apps signed at once
- Remove a sideloaded app from AltStore → My Apps → swipe to remove
- This frees up a slot

**"App could not be installed" / code signing error**
- The IPA may have been corrupted during transfer
- Re-download from Codemagic artifacts and try again
- Check that iCloud is signed into the same Apple ID as AltStore

**App crashes on launch**
- The unsigned IPA built by Codemagic may have entitlement issues
- Open Codemagic build logs and look for any signing warnings
- Firebase should work without `GoogleService-Info.plist` since the app initializes Firebase programmatically via `firebase_options.dart`

**"Xcode could not find any provisioning profiles"** (in Codemagic logs)
- This is expected and harmless — we are intentionally building with `--no-codesign`
- As long as the IPA artifact appears in the Artifacts tab, the build succeeded

---

### AltStore vs PWA — Which Should I Use?

| | PWA | AltStore Native IPA |
|---|---|---|
| Installation | Safari/Chrome → Add to Home Screen | AltServer → AltStore |
| Expiry | Never | Every 7 days (auto-renewed) |
| Setup complexity | None | Medium (one-time) |
| Works without PC | Yes | Yes (after install) |
| Full native iOS APIs | No | Yes |
| Push notifications | No | No (free Apple ID) |
| Offline capable | Partial | Yes |
| Firestore real-time | Yes | Yes |
| ESP32 live status | Via Firestore | Via Firestore + local HTTP |
| Best for | Quick access anywhere | Best native experience |

**My recommendation:** Use the PWA for daily monitoring. Set up AltStore only if you need native features (camera, local network HTTP to ESP32 without mixed content issues).

---

## 9. Full Code Reference


These are the exact prompts I used with Claude Code (AI coding assistant) to build this system. Anyone can use these same prompts to replicate or extend the project from scratch.

---

### Checking Platform Readiness
```
is the app ios and android ready?
```
*Led to: checking android/, ios/ folders for scaffolding, google-services.json, GoogleService-Info.plist, bundle IDs*

---

### Investigating iOS Distribution
```
yes please and also [continued into Codemagic/TestFlight question]
```
```
I have a Flutter app ready. Generate a complete codemagic.yaml for iOS
distribution to my iPhone via TestFlight.

Requirements:
- Flutter stable channel
- iOS build with proper code signing
- Publish to TestFlight via App Store Connect API
- Use environment variables for all secrets (no hardcoded values)
- Include these env var placeholders:
    APP_STORE_CONNECT_ISSUER_ID
    APP_STORE_CONNECT_KEY_IDENTIFIER
    APP_STORE_CONNECT_PRIVATE_KEY
    CERTIFICATE_PRIVATE_KEY

Also generate:
1. A checklist of everything I need to set up in the Codemagic dashboard
2. Step-by-step instructions to get my Apple Distribution Certificate
   and Provisioning Profile from developer.apple.com without a Mac
3. Where to paste each secret in the Codemagic UI

My bundle ID is: com.yourname.appname
My app name is: MyApp
```
*Led to: full codemagic.yaml, dashboard checklist, certificate instructions*

---

### Realizing the $99 Problem
```
isnt using codemagic allow me to bypass the 99 dollar apple account
```
*Led to: explanation that Codemagic is a build server only, Apple Developer Program is still required*

---

### Choosing PWA Instead
```
i only have iphone no mac and only windows and no money for 99 dollar
and just wanna test out on my phone
```
*Led to: PWA recommendation, explanation that Flutter web works perfectly for this app*

---

### Setting Up PWA + Firebase Hosting
```
yes do all 3
```
*(referring to: 1. check flutter build web works, 2. set up Firebase Hosting, 3. add PWA install config)*

*Led to:*
- *Updating `web/manifest.json` with correct name, theme, colors*
- *Updating `web/index.html` with iOS PWA meta tags*
- *Creating `firebase.json` with hosting config*
- *Creating `.firebaserc` linking to Firebase project*
- *Running `flutter build web --release` (fixed build error from unused packages)*
- *Running `firebase deploy --only hosting`*
- *Deployed to `https://smart-toolbox-b0455.web.app`*

---

### Fixing Bundle ID
```
fix bundle id and i am an individual and not a team
```
*Led to: finding mismatch between CLAUDE.md (com.layer6.toolbox) and actual code (com.layer6.tooltrack), fixing CLAUDE.md*

---

### Fixing Live Status on PWA
```
fix the esp32 live status on pwa
```
*Led to: diagnosing mixed content policy, designing Firestore push solution, implementing `pushLiveStatus()` in firmware, updating Flutter to subscribe to `live_status/current`*

---

### Autonomous Execution
```
do everything that is required and work on it dont ask me for anything
```
*Led to: full autonomous implementation — reading all files, making all code changes, running build, deploying, without prompting for confirmation*

---

### AltStore Sideloading (Native iOS, No $99)

```
Build my Flutter app as an .ipa for AltStore sideloading using
a free Apple ID (no paid developer account).

Set up Codemagic to:
1. Build unsigned .ipa
2. Sign it with a free Apple ID certificate
3. Output the .ipa as a build artifact I can download

Also give me step-by-step instructions to:
1. Install AltStore on my iPhone from a Windows PC
2. Sideload the downloaded .ipa using AltStore
3. Set up AltServer on Windows for the 7-day auto-resign
```

*Led to: `codemagic.yaml` for unsigned IPA build, AltServer Windows setup guide, AltStore install steps, 7-day auto-resign config, comparison table PWA vs native IPA*

---

### Documentation
```
also create a fabacademy documentation.md file and it should be updated
with how everything works and how everything has been setup and all the
prompts that i used or once can use to setup things and update that always
during all the prompts etc
```

```
update the documentation with the esp32 live status fix
```

```
fully detailed documentation in the fabacademy style
```

---

### Prompts to Extend This System in the Future

**Add a new tool:**
```
Add a 5th tool called "Oscilloscope" wired to pin D8 on the ESP32.
Update the firmware to track it and add it to the Flutter app tool list.
```

**Add push notifications:**
```
Add Firebase Cloud Messaging to the Flutter app so I get a push
notification on my phone whenever any tool is taken out.
```

**Add a reservations system:**
```
Add a Reservations screen to the Flutter app where users can book
a tool for a specific time slot. Store reservations in Firestore.
Prevent double-booking. Show conflicts in the Activity feed.
```

**Add analytics:**
```
Add a Stats screen showing: most used tool this week, most active
user, average checkout duration per tool. Use existing Firestore data.
```

**Multi-drawer support:**
```
Add a second drawer (Drawer 2) with its own reed switch on pin [X]
and 4 more tool buttons. Update both the firmware and Flutter app.
```

**Change app theme:**
```
Change the color theme from warm orange/cream to dark mode with a
deep navy background and cyan accent. Keep all functionality the same.
```

**Add offline support:**
```
Add PWA offline support so the app shows the last known tool status
when there is no internet connection. Use service workers.
```

**Multi-toolbox support:**
```
Update the system to support multiple toolboxes. Each ESP32 has a
unique ID. The Flutter app can switch between toolboxes.
```

---

## 10. What I Learned

### Embedded Systems
- `INPUT_PULLUP` inverts button logic — need to think carefully about what HIGH/LOW means for each sensor
- Button debouncing is essential; 50ms is a good starting value for mechanical buttons
- The ESP32 can make outbound HTTPS requests using `HTTPClient` just like an HTTP request — TLS is handled automatically
- NVM via `Preferences` is reliable and survives power loss, but you need to manage your own key index if you want to iterate over all stored values
- WiFiManager saves a lot of boilerplate but requires port 80 for the captive portal, which conflicts with using port 80 for the admin server

### Firebase / Cloud
- Firestore REST API (`POST` = create new doc, `PATCH` = create/update specific doc) — mixing these up caused me to create duplicate documents initially
- `epochMs` as a string integer field is needed for Flutter sorting because Firestore's native timestamp ordering requires a different SDK query approach
- FlutterFire CLI (`flutterfire configure`) generates all platform configs at once — much easier than manually creating platform-specific Firebase config files

### Flutter / PWA
- `flutter build web` fails if `pubspec.yaml` lists packages that don't have web implementations, even if you never import them in code — the auto-generated plugin registrant tries to import them all
- `flutter clean` is the nuclear option that fixes most strange build cache issues
- PWAs installed to iPhone home screen still enforce HTTPS mixed content rules — this is a WebKit restriction, not a Safari-specific one, so Chrome on iOS has the same behavior
- Firebase Hosting forces HTTPS — this is good for security but means any local HTTP device (like ESP32) cannot be reached from the PWA unless you route through Firestore

### Architecture
- Having the IoT device push state TO the cloud (rather than the app polling the device) is more robust, works from anywhere, and solves the HTTP/HTTPS mixed content problem entirely
- A single Firestore document for live state (PATCH) + a collection for history (POST) is a clean pattern for IoT dashboards

---

## 11. Files & Downloads

| File | Path | Description |
|------|------|-------------|
| ESP32 Firmware | `tool box test/src/main.cpp` | All firmware, ~1000 lines |
| Flutter App | `toolbox_app/lib/main.dart` | All screens, ~1400 lines |
| Firebase Options | `toolbox_app/lib/firebase_options.dart` | Platform Firebase config |
| Firebase Config | `toolbox_app/firebase.json` | Hosting + FlutterFire config |
| Firebase Project | `toolbox_app/.firebaserc` | Project ID link |
| PWA Manifest | `toolbox_app/web/manifest.json` | Install behavior, icons |
| PWA HTML | `toolbox_app/web/index.html` | iOS PWA meta tags |
| Android Firebase | `toolbox_app/android/app/google-services.json` | Android config |
| Codemagic CI | `toolbox_app/codemagic.yaml` | Unsigned IPA build for AltStore |
| This Doc | `fabacademy documentation.md` | You are here |

**Live PWA URL:** `https://smart-toolbox-b0455.web.app`

---

## 12. Troubleshooting Log

### ESP32 won't connect to WiFi
1. Wait for the "ToolBox by Layer6" hotspot to appear (usually within 30s of boot)
2. Connect phone/PC to that hotspot (password: `setup1234`)
3. Browse to `http://192.168.4.1`
4. Enter your WiFi credentials and save
5. Device restarts and connects

### Firestore not receiving tool events
- Open admin panel → check serial monitor for `[FIRESTORE]` lines
- `✗ Error: HTTP 400` → check JSON format in `logToFirestore()`
- `⚠ WiFi not connected` → device is in AP-only mode, connect to WiFi first
- No `[FIRESTORE]` lines at all → check `FIREBASE_PROJECT_ID` and `FIREBASE_API_KEY` constants

### PWA Box tab shows "Device: Off"
- ESP32 must be on WiFi (not AP mode) to push to Firestore
- Press any tool button on the ESP32 to trigger an immediate `pushLiveStatus()` call
- Check Firestore console → `live_status` collection → `current` document should exist
- If document doesn't exist, the ESP32 firmware may not have the `pushLiveStatus()` function — re-flash

### Flutter web build fails with plugin errors
```bash
flutter clean
flutter pub get
flutter build web --release
```
If still failing, check `pubspec.yaml` for any packages that don't support web (remove them if unused).

### Firebase deploy fails with auth error
```bash
firebase login   # opens browser to re-authenticate
firebase deploy --only hosting
```

### Members screen shows empty
- Members are fetched from ESP32 `/api/users` over local HTTP
- Phone and ESP32 must be on the same WiFi network
- Enter the correct ESP32 IP in Settings tab first
- Verify auth: the app sends `Cookie: auth=1` — if the ESP32 rebooted, the session is still valid (cookie-based, not server-side session)

### App shows old data after deploying update
- Hard refresh in browser: `Ctrl+Shift+R` (or on iPhone: close and reopen from home screen)
- `index.html` is set to `no-cache` so updates should be instant
- JS/CSS/WASM are content-hashed so new builds always have new filenames

---

## 13. Re-deploying After Changes

### After any Flutter code change:
```bash
cd "MOBILE APP/toolbox_app"
flutter build web --release
firebase deploy --only hosting
```

### After any ESP32 firmware change:
1. Open VS Code in `tool box test/` folder
2. PlatformIO sidebar (ant icon) → **Upload**
3. Watch Serial Monitor for boot confirmation

### After changing both:
Run the Flutter commands first (deploy takes ~1 min), then re-flash ESP32.

---

*This document is maintained alongside the codebase and updated after every significant change, feature, or debugging session.*
