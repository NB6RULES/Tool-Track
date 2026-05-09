# ToolBox RFID Access System — CLAUDE.md

## Project Overview
ESP32-S3 (Seeed XIAO) based RFID tool tracking system. Users tap RFID cards to unlock a solenoid drawer, tool checkout is tracked via physical buttons, and all events are logged to Firebase Firestore. Admin panel served on port 8080.

## Hardware
- **Board:** Seeed XIAO ESP32-S3
- **RFID:** RC522 (SPI)
- **Lock:** Solenoid via relay/MOSFET on D7
- **Drawer sensor:** Reed switch on D6 (LOW = closed, HIGH = open)
- **Tool buttons:** D0 Caliper, D2 Plier, D4 Micrometer, D5 Tweezer (INPUT_PULLUP, LOW = pressed = tool taken)

## Pin Map
| Pin | Function |
|-----|----------|
| D8  | SPI SCK (RC522) |
| D9  | SPI MISO (RC522) |
| D10 | SPI MOSI (RC522) |
| D3  | SS_PIN (RC522) |
| D1  | RST_PIN (RC522) |
| D7  | Solenoid lock |
| D6  | Reed switch drawer 1 |
| D0  | Button: Caliper |
| D2  | Button: Plier |
| D4  | Button: Micrometer |
| D5  | Button: Tweezer |

## Build & Upload
**Do NOT use `pio run` from CLI** — system Python is 3.14 which PlatformIO does not support (requires 3.10–3.13).
Always build/upload via the **VS Code PlatformIO extension** (ant icon sidebar → Upload).

## Key Architecture

### WiFi (WiFiManager)
- Uses `tzapu/WiFiManager` — handles all WiFi credential storage and config portal
- On boot: tries saved credentials silently
- If no credentials / fail: opens AP **"ToolBox by Layer6"** (password: `setup1234`)
  - Captive portal on port 80: WiFi config + "Open Admin Panel" button
  - Admin panel on port 8080: `http://192.168.4.1:8080`
- If portal times out (3 min): falls back to standalone AP, admin still at `192.168.4.1:8080`
- To reset WiFi: admin panel → WiFi panel → "Reset WiFi" button (`/api/wifi/reset`)

### Web Server
- Runs on **port 8080** (never port 80 — reserved for WiFiManager portal)
- Cookie-based auth (`auth=1`), credentials: `admin` / `admin123`
- All routes require authentication except `/login`

### API Routes
| Method | Route | Description |
|--------|-------|-------------|
| GET | `/` | Dashboard (redirects to `/login` if not authed) |
| GET | `/login` | Login page |
| GET | `/logout` | Clear cookie, redirect to login |
| POST | `/api/login` | JSON `{user, pass}` → sets auth cookie |
| GET | `/api/serial` | Serial log buffer + lastScannedUID |
| GET | `/api/users` | All authorized users as JSON |
| POST | `/api/users/add` | JSON `{uid, name}` → save user |
| POST | `/api/users/delete` | JSON `{uid}` → remove user |
| POST | `/api/wifi/reset` | Reset WiFiManager credentials + restart |
| GET | `/api/tools` | Live tool + drawer states |
| GET | `/api/status` | Current IP, SSID, RSSI |

### Storage (Preferences)
- `users` namespace: key = UID string, value = name string
- `userkeys` namespace: key = `"keys"`, value = pipe-separated UID list (e.g. `"AA BB CC|DD EE FF"`)
- WiFi credentials stored by WiFiManager internally (not in `prefs`)

### Firebase Firestore
- Project: `smart-toolbox-b0455`
- Collection: `tool_logs`
- Logged on tool taken: `{userName, uid, drawer, tool, timestamp}`
- Skipped silently if WiFi not connected

## Dependencies (platformio.ini)
```
mguelbalboa/MFRC522@^1.4.12
ArduinoJson@^6.18.5
tzapu/WiFiManager@^2.0.17
```

## Coding Conventions
- `webLog()` for all log messages — writes to Serial and the in-memory ring buffer shown in dashboard
- Do NOT call `webLog()` inside `/api/serial` handler (causes infinite self-logging every 2s poll)
- Solenoid auto-locks after `SOLENOID_TIMEOUT` (10s) from open
- Button debounce: 50ms (`DEBOUNCE_MS`)
- NTP timezone: IST = UTC+5:30 (`configTime(19800, 0, "pool.ntp.org")`)
