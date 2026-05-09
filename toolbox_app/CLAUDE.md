# ToolBox Flutter App — CLAUDE.md

## Project Overview
Flutter Android app for the Smart ToolBox system. Monitors RFID access, drawer open/close,
and tool checkout/return events. Data comes from two sources:
1. **Firebase Firestore** — historical log of all events (tool taken/returned)
2. **ESP32 local REST API** — live real-time hardware state (who's in, which drawer is open, tool states)

No Firebase SDK is used — Firestore is accessed via its REST API with the project API key.
This avoids needing google-services.json and keeps setup simple.

## Firebase / Firestore
- **Project ID:** `smart-toolbox-b0455`
- **API Key:** `AIzaSyCYQFnhupq9GiL7P0D5VeIftWvh3ePTKSs`
- **Collection:** `tool_logs`
- **REST base:** `https://firestore.googleapis.com/v1/projects/smart-toolbox-b0455/databases/(default)/documents`

### tool_logs document schema
```
userName:  string   — Full name of person who tapped RFID
uid:       string   — RFID card UID (e.g. "AA BB CC DD")
drawer:    string   — "Drawer 1"
tool:      string   — "Caliper" | "Plier" | "Micrometer" | "Tweezer"
timestamp: string   — "HH:MM:SS-DD-MM-YYYY" (IST)
action:    string   — "taken" | "returned"
```

## ESP32 Local API
- **Default AP IP:** `192.168.4.1:8080` (when no WiFi configured)
- **LAN IP:** stored by user in app Settings screen
- **Auth:** Cookie `auth=1` (hardcoded admin session — no real auth needed for local LAN)
- All calls timeout after 5 seconds; failures are silently swallowed (device may be offline)

### API Endpoints used
| Method | Endpoint        | Description                        |
|--------|-----------------|------------------------------------|
| GET    | /api/tools      | Live tool + drawer states (JSON)   |
| GET    | /api/users      | List of authorized RFID users      |
| GET    | /api/status     | Device IP, SSID, RSSI              |

### /api/tools response
```json
{
  "caliper": false,
  "plier": false,
  "micrometer": true,
  "tweezer": false,
  "drawer1": false
}
```
`true` = tool is OUT / drawer is OPEN

### /api/users response
```json
{
  "users": [
    {"uid": "AA BB CC DD", "name": "John Smith"}
  ]
}
```

## App Architecture

### Directory structure
```
lib/
  main.dart              — App entry, theme, bottom nav
  models/
    tool_log.dart        — ToolLog model, Firestore doc parser
  services/
    firestore_service.dart  — Firestore REST API calls
    esp32_service.dart      — ESP32 HTTP calls + IP storage
  screens/
    dashboard_screen.dart   — Summary stats + live status + recent events
    activity_screen.dart    — Full log list, filterable by tool/user/action
    tool_status_screen.dart — Live tool grid from ESP32 + last seen from Firestore
    users_screen.dart       — Authorized users list from ESP32
    settings_screen.dart    — ESP32 IP configuration
```

### Theme constants (defined in main.dart)
```dart
const kBg     = Color(0xFF0A0A0F);  // page background
const kPanel  = Color(0xFF12121A);  // card background
const kBorder = Color(0xFF2A2A3A);  // card border
const kAccent = Color(0xFF00FF9D);  // green accent
const kWarn   = Color(0xFFFF6B35);  // orange warning
const kText   = Color(0xFFE0E0F0);  // body text
const kMuted  = Color(0xFF666680);  // secondary text
```

### Refresh strategy
- Dashboard and Tool Status: poll every 10 seconds via Timer.periodic
- Activity screen: manual pull-to-refresh + load on mount
- Users screen: load on mount + manual refresh button

## Dependencies (pubspec.yaml)
```yaml
http: ^1.2.2               — REST API calls
shared_preferences: ^2.3.2 — Store ESP32 IP across sessions
intl: ^0.19.0              — Date formatting
```

## Build & Run

### Prerequisites
1. Flutter SDK 3.19+ installed
2. Android Studio or VSCode with Flutter extension
3. Android device or emulator (API 21+)

### First-time setup
```bash
cd "C:\Users\nadec\OneDrive\Desktop\VIBE-CODING\MOBILE APP\toolbox_app"
flutter pub get
flutter run
```

### Connect to ESP32
- On same WiFi as ESP32: enter device IP in Settings screen
- Direct AP mode (no WiFi): connect phone to "ToolBox by Layer6" hotspot, IP is 192.168.4.1

## Android Configuration
- **Package name:** `com.layer6.tooltrack`
- **Min SDK:** 21 (Android 5.0)
- **Target SDK:** 34
- **Internet permission** required in AndroidManifest.xml (already set)

## Coding Conventions
- All Firestore/ESP32 errors are caught and return null/empty — app degrades gracefully
- `kAccent`/`kWarn` colors match the existing web dashboard aesthetic
- No setState calls after dispose (all async calls check `if (mounted)`)
- Tool names match exactly what firmware logs: "Caliper", "Plier", "Micrometer", "Tweezer"
- RFID UIDs formatted as "AA BB CC DD" (uppercase, space-separated)
