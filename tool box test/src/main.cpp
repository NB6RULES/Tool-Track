/*
 * ToolBox RFID Access System
 * Hardware: Seeed XIAO ESP32-S3
 * 
 * PIN MAPPING:
 * D8  - SPI SCK  (RC522)
 * D9  - SPI MISO (RC522)
 * D10 - SPI MOSI (RC522)
 * D3  - SS_PIN   (RC522)
 * D1  - RST_PIN  (RC522)
 * D7  - SOLENOID LOCK (via relay/MOSFET)
 * D6  - REED SWITCH (Drawer 1 open sensor) - INPUT_PULLUP
 * D0  - TOOL: CALIPER   button - INPUT_PULLUP
 * D2  - TOOL: PLIER     button - INPUT_PULLUP
 * D4  - TOOL: MICROMETER button - INPUT_PULLUP
 * D5  - TOOL: TWEEZER   button - INPUT_PULLUP
 */

#include <SPI.h>
#include <MFRC522.h>
#include <WiFi.h>
#include <WebServer.h>
#include <WiFiManager.h>
#include <Preferences.h>
#include <ArduinoJson.h>
#include <HTTPClient.h>
#include <ESPmDNS.h>
#include <time.h>

// ─── PIN DEFINITIONS ──────────────────────────────────────────────
#define SPI_SCK     D8
#define SPI_MISO    D9
#define SPI_MOSI    D10
#define SS_PIN      D3
#define RST_PIN     D1
#define SOLENOID    D7

#define REED_DRAW1  D6   // Drawer 1 reed switch

#define BTN_CALIPER    D0
#define BTN_PLIER      D2
#define BTN_MICROMETER D4
#define BTN_TWEEZER    D5

// ─── ADMIN CREDENTIALS (hardcoded) ───────────────────────────────
#define ADMIN_USER  "admin"
#define ADMIN_PASS  "admin123"

// ─── FIRESTORE CONFIG ─────────────────────────────────────────────
// Replace with your Firebase project details
#define FIREBASE_PROJECT_ID  "smart-toolbox-b0455"
#define FIREBASE_API_KEY     "AIzaSyCYQFnhupq9GiL7P0D5VeIftWvh3ePTKSs"
// Firestore REST endpoint
String firestoreBase = "https://firestore.googleapis.com/v1/projects/" 
                        FIREBASE_PROJECT_ID 
                        "/databases/(default)/documents/tool_logs";

// ─── GLOBALS ──────────────────────────────────────────────────────
MFRC522 rfid(SS_PIN, RST_PIN);
WebServer server(80);
Preferences prefs;

String lastScannedUID    = "";
bool   adminLoggedIn     = false;
bool   drawerOpen        = false;
String currentUserName   = "";
String currentUserUID    = "";
unsigned long solenoidOpenTime = 0;
#define SOLENOID_TIMEOUT 10000  // 10 seconds

// Tool states (true = taken out)
bool toolCaliper    = false;
bool toolPlier      = false;
bool toolMicrometer = false;
bool toolTweezer    = false;

// Button debounce
#define DEBOUNCE_MS 50
struct DebouncedButton {
  uint8_t pin;
  bool state;
  bool lastRaw;
  unsigned long lastChange;
};

DebouncedButton btns[4]; // caliper, plier, micrometer, tweezer

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

// Serial monitor buffer for web display
#define LOG_BUFFER_SIZE 50
String logBuffer[LOG_BUFFER_SIZE];
int    logHead = 0;
int    logCount = 0;

// ─── HELPER: Add to web serial log ────────────────────────────────
void webLog(String msg) {
  Serial.println(msg);
  logBuffer[logHead] = msg;
  logHead = (logHead + 1) % LOG_BUFFER_SIZE;
  if (logCount < LOG_BUFFER_SIZE) logCount++;
}

// ─── HELPER: Get current timestamp ────────────────────────────────
String getTimestamp() {
  struct tm timeinfo;
  if (!getLocalTime(&timeinfo)) return "00:00:00-00-00-0000";
  char buf[30];
  strftime(buf, sizeof(buf), "%H:%M:%S-%d-%m-%Y", &timeinfo);
  return String(buf);
}

// ─── HELPER: Format UID bytes to string "XX XX XX XX" ─────────────
String uidToString(byte *uid, byte size) {
  String result = "";
  for (int i = 0; i < size; i++) {
    if (uid[i] < 0x10) result += "0";
    result += String(uid[i], HEX);
    if (i < size - 1) result += " ";
  }
  result.toUpperCase();
  return result;
}

// ─── HELPER: Check if UID is authorized ───────────────────────────
String getAuthorizedName(String uid) {
  prefs.begin("users", true); // read-only
  String name = prefs.getString(uid.c_str(), "");
  prefs.end();
  return name; // empty string = not authorized
}

// ─── HELPER: Save user to preferences ─────────────────────────────
void saveUser(String uid, String name) {
  prefs.begin("users", false);
  prefs.putString(uid.c_str(), name);
  prefs.end();
  webLog("[USER SAVED] " + name + " | UID: " + uid);
}

// ─── HELPER: Delete user ───────────────────────────────────────────
void deleteUser(String uid) {
  prefs.begin("users", false);
  prefs.remove(uid.c_str());
  prefs.end();
  webLog("[USER DELETED] UID: " + uid);
}

// ─── HELPER: Get all users as JSON ────────────────────────────────
String getAllUsersJSON() {
  prefs.begin("users", true);
  StaticJsonDocument<4096> doc;
  JsonArray arr = doc.createNestedArray("users");
  // Iterate all keys in namespace
  // ArduinoJson + Preferences: we store a known index list separately
  prefs.end();

  // We maintain a separate "userkeys" namespace to track UIDs
  prefs.begin("userkeys", true);
  String keysRaw = prefs.getString("keys", "");
  prefs.end();

  if (keysRaw.length() > 0) {
    // keys stored as "UID1|UID2|UID3"
    int start = 0;
    prefs.begin("users", true);
    while (start < (int)keysRaw.length()) {
      int sep = keysRaw.indexOf('|', start);
      if (sep == -1) sep = keysRaw.length();
      String uid = keysRaw.substring(start, sep);
      String name = prefs.getString(uid.c_str(), "");
      if (name.length() > 0) {
        JsonObject obj = arr.createNestedObject();
        obj["uid"] = uid;
        obj["name"] = name;
      }
      start = sep + 1;
    }
    prefs.end();
  }

  String out;
  serializeJson(doc, out);
  return out;
}

// ─── HELPER: Add UID to key index ─────────────────────────────────
void addToKeyIndex(String uid) {
  prefs.begin("userkeys", false);
  String existing = prefs.getString("keys", "");
  if (existing.indexOf(uid) == -1) {
    if (existing.length() > 0) existing += "|";
    existing += uid;
    prefs.putString("keys", existing);
  }
  prefs.end();
}

void removeFromKeyIndex(String uid) {
  prefs.begin("userkeys", false);
  String existing = prefs.getString("keys", "");
  existing.replace(uid + "|", "");
  existing.replace("|" + uid, "");
  existing.replace(uid, "");
  prefs.putString("keys", existing);
  prefs.end();
}

// ─── FIRESTORE: Log tool event ─────────────────────────────────────
void logToFirestore(String userName, String uid, String drawer, String tool, String timestamp, String action = "taken") {
  if (WiFi.status() != WL_CONNECTED) {
    webLog("[FIRESTORE] ⚠ WiFi not connected, skipping cloud log");
    return;
  }

  webLog("[FIRESTORE] 📤 Sending log: " + userName + " took " + tool);
  HTTPClient http;
  String url = firestoreBase + "?key=" + FIREBASE_API_KEY;
  http.begin(url);
  http.addHeader("Content-Type", "application/json");

  // Build Firestore document JSON
  StaticJsonDocument<512> doc;
  JsonObject fields = doc.createNestedObject("fields");

  fields["userName"]["stringValue"]  = userName;
  fields["uid"]["stringValue"]       = uid;
  fields["drawer"]["stringValue"]    = drawer;
  fields["tool"]["stringValue"]      = tool;
  fields["timestamp"]["stringValue"] = timestamp;
  fields["action"]["stringValue"]    = action;

  // Unix epoch milliseconds for sorting in Flutter
  struct tm timeinfo;
  if (getLocalTime(&timeinfo)) {
    fields["epochMs"]["integerValue"] = String((long long)mktime(&timeinfo) * 1000LL);
  }

  String body;
  serializeJson(doc, body);

  int code = http.POST(body);
  if (code == 200 || code == 201) {
    webLog("[FIRESTORE] ✓ Cloud log saved | " + tool + " | " + timestamp);
  } else {
    webLog("[FIRESTORE] ✗ Error: HTTP " + String(code) + " - " + tool);
  }
  http.end();
}

// ─── SOLENOID CONTROL ─────────────────────────────────────────────
void openSolenoid() {
  digitalWrite(SOLENOID, HIGH);
  solenoidOpenTime = millis();
  webLog("[SOLENOID] UNLOCKED");
}

void closeSolenoid() {
  digitalWrite(SOLENOID, LOW);
  webLog("[SOLENOID] LOCKED");
}

// ─── WiFi SETUP ───────────────────────────────────────────────────
void connectWiFi() {
  webLog("[WiFi] Starting WiFiManager...");
  WiFiManager wm;
  wm.setConfigPortalTimeout(180); // 3 min to configure, then continue

  // Style the WiFiManager portal to match the admin panel design system
  wm.setCustomHeadElement(
    "<link rel='preconnect' href='https://fonts.googleapis.com'>"
    "<link href='https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;700&family=Bebas+Neue&display=swap' rel='stylesheet'>"
    "<style>"
      "body,html{background:#0a0a0f!important;color:#e0e0f0!important;font-family:'JetBrains Mono',monospace!important}"
      ".wrap{background:#12121a!important;border:1px solid #2a2a3a!important;border-radius:8px!important;max-width:420px!important}"
      "h1,h2,h3{font-family:'Bebas Neue',sans-serif!important;letter-spacing:3px!important;color:#00ff9d!important}"
      "input[type=text],input[type=password],select{"
        "background:#050508!important;border:1px solid #2a2a3a!important;"
        "color:#e0e0f0!important;font-family:'JetBrains Mono',monospace!important;"
        "border-radius:4px!important;padding:10px 14px!important}"
      "input:focus,select:focus{outline:none!important;border-color:#00ff9d!important}"
      "input[type=submit],button{"
        "background:#00ff9d!important;color:#000!important;border:none!important;"
        "font-family:'JetBrains Mono',monospace!important;font-weight:700!important;"
        "letter-spacing:1px!important;text-transform:uppercase!important;"
        "border-radius:4px!important;padding:10px 20px!important;cursor:pointer!important}"
      "input[type=submit]:hover,button:hover{opacity:0.85!important}"
      "a{color:#00ff9d!important}"
      "hr{border-color:#2a2a3a!important}"
      ".msg{background:#12121a!important;border:1px solid #2a2a3a!important;color:#e0e0f0!important;border-radius:4px!important}"
      ".tb-header{text-align:center;padding:18px 0 8px 0;border-bottom:1px solid #2a2a3a;margin-bottom:16px}"
      ".tb-header h1{font-family:'Bebas Neue',sans-serif;font-size:28px;letter-spacing:3px;color:#00ff9d;margin:0}"
      ".tb-header p{font-size:11px;color:#666680;letter-spacing:1px;margin-top:4px}"
    "</style>"
    "<script>"
      "window.addEventListener('load',function(){"
        "var wrap=document.querySelector('.wrap');"
        "if(!wrap)return;"
        "var hdr=document.createElement('div');"
        "hdr.className='tb-header';"
        "hdr.innerHTML='<h1>&#9881; TOOLBOX</h1><p>WIFI CONFIGURATION</p>';"
        "wrap.insertBefore(hdr,wrap.firstChild);"
      "});"
    "</script>"
  );

  // Called when config portal opens
  wm.setAPCallback([](WiFiManager *mgr) {
    Serial.println("[WiFi] Config portal open — SSID: ToolBox by Layer6");
    Serial.println("[WiFi] WiFi setup: http://192.168.4.1");
  });

  bool connected = wm.autoConnect("ToolBox by Layer6", "setup1234");

  if (connected) {
    webLog("[WiFi] ═══════════════════════════════════════════");
    webLog("[WiFi] Connected! IP: " + WiFi.localIP().toString());
    webLog("[WiFi] Signal strength: " + String(WiFi.RSSI()) + " dBm");
    webLog("[WiFi] Admin panel: http://" + WiFi.localIP().toString());
    webLog("[WiFi] ═══════════════════════════════════════════");
    configTime(19800, 0, "pool.ntp.org"); // IST = UTC+5:30
    webLog("[WiFi] NTP time sync started");
    if (MDNS.begin("toolbox")) {
      MDNS.addService("http", "tcp", 80);
      webLog("[mDNS] Hostname: http://toolbox.local");
    }
  } else {
    webLog("[WiFi] Config portal timed out — no WiFi, cloud logging disabled");
    // No WiFi — start a standalone AP so the admin panel is still reachable
    WiFi.mode(WIFI_AP);
    WiFi.softAP("ToolBox by Layer6", "setup1234");
    webLog("[WiFi] ═══════════════════════════════════════════");
    webLog("[WiFi] Fallback AP started");
    webLog("[WiFi] Admin panel: http://192.168.4.1");
    webLog("[WiFi] ═══════════════════════════════════════════");
    if (MDNS.begin("toolbox")) {
      MDNS.addService("http", "tcp", 80);
      webLog("[mDNS] Hostname: http://toolbox.local");
    }
  }
}

// ═══════════════════════════════════════════════════════════════════
//  WEB SERVER ROUTES
// ═══════════════════════════════════════════════════════════════════

// ─── Auth check helper ─────────────────────────────────────────────
bool isAuthenticated() {
  if (server.hasHeader("Cookie")) {
    String cookie = server.header("Cookie");
    if (cookie.indexOf("auth=1") != -1) return true;
  }
  return false;
}

// ─── GET / → Main dashboard ───────────────────────────────────────
void handleRoot() {
  if (!isAuthenticated()) {
    webLog("[WEB] GET / - UNAUTHORIZED (redirecting to login)");
    server.sendHeader("Location", "/login");
    server.send(302);
    return;
  }
  webLog("[WEB] GET / - Dashboard loaded");
  // Serve dashboard HTML (inline)
  String html = R"rawhtml(
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ToolBox Admin</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;700&family=Bebas+Neue&display=swap');
  :root {
    --bg: #0a0a0f;
    --panel: #12121a;
    --border: #2a2a3a;
    --accent: #00ff9d;
    --warn: #ff6b35;
    --text: #e0e0f0;
    --muted: #666680;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { background: var(--bg); color: var(--text); font-family: 'JetBrains Mono', monospace; min-height: 100vh; }
  header { border-bottom: 1px solid var(--border); padding: 16px 32px; display: flex; align-items: center; justify-content: space-between; }
  header h1 { font-family: 'Bebas Neue', sans-serif; font-size: 28px; letter-spacing: 3px; color: var(--accent); }
  header span { color: var(--muted); font-size: 12px; }
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; padding: 24px 32px; }
  .panel { background: var(--panel); border: 1px solid var(--border); border-radius: 8px; padding: 20px; }
  .panel h2 { font-size: 11px; letter-spacing: 2px; color: var(--muted); text-transform: uppercase; margin-bottom: 16px; border-bottom: 1px solid var(--border); padding-bottom: 10px; }
  .serial-monitor { background: #050508; border: 1px solid var(--border); border-radius: 4px; height: 280px; overflow-y: auto; padding: 12px; font-size: 12px; line-height: 1.8; }
  .serial-monitor .line { color: #7fff9d; }
  .serial-monitor .line.warn { color: var(--warn); }
  .uid-display { background: #050508; border: 1px solid var(--accent); border-radius: 4px; padding: 16px; text-align: center; margin: 12px 0; }
  .uid-display .uid-val { font-size: 22px; letter-spacing: 4px; color: var(--accent); font-weight: 700; }
  .uid-display .uid-label { font-size: 10px; color: var(--muted); margin-top: 4px; }
  input[type=text], input[type=password] { 
    width: 100%; background: #050508; border: 1px solid var(--border); 
    color: var(--text); padding: 10px 14px; border-radius: 4px; 
    font-family: 'JetBrains Mono', monospace; font-size: 13px; margin: 6px 0;
  }
  input:focus { outline: none; border-color: var(--accent); }
  button { 
    background: var(--accent); color: #000; border: none; padding: 10px 20px; 
    border-radius: 4px; font-family: 'JetBrains Mono', monospace; font-weight: 700; 
    font-size: 12px; letter-spacing: 1px; cursor: pointer; margin: 4px 2px;
    text-transform: uppercase;
  }
  button:hover { opacity: 0.85; }
  button.danger { background: var(--warn); }
  button.secondary { background: transparent; color: var(--text); border: 1px solid var(--border); }
  .user-list { max-height: 220px; overflow-y: auto; }
  .user-item { display: flex; align-items: center; justify-content: space-between; padding: 10px 0; border-bottom: 1px solid var(--border); }
  .user-item .name { font-size: 13px; }
  .user-item .uid-small { font-size: 10px; color: var(--muted); margin-top: 2px; }
  .status-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--accent); display: inline-block; margin-right: 6px; animation: pulse 2s infinite; }
  @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.3} }
  .wifi-form input { margin: 4px 0; }
  .tag { background: #1a2a1a; color: var(--accent); border: 1px solid #2a4a2a; padding: 2px 8px; border-radius: 3px; font-size: 10px; }
  a.logout { color: var(--muted); font-size: 11px; text-decoration: none; }
  a.logout:hover { color: var(--warn); }
  @media(max-width:700px){ .grid{grid-template-columns:1fr; padding:12px;} }
</style>
</head>
<body>
<header>
  <h1>⚙ ToolBox Admin</h1>
  <div style="display:flex;align-items:center;gap:16px">
    <span><span class="status-dot"></span><span id="devIP">...</span></span>
    <a href="/logout" class="logout">[ LOGOUT ]</a>
  </div>
</header>
<div class="grid">

  <!-- Serial Monitor -->
  <div class="panel" style="grid-column:1/-1">
    <h2>📡 Serial Monitor</h2>
    <div class="serial-monitor" id="serialMon">Loading...</div>
  </div>

  <!-- New Card Scan + Add User -->
  <div class="panel">
    <h2>➕ Add New User</h2>
    <p style="font-size:11px;color:var(--muted);margin-bottom:12px">Tap a new card on the reader — the UID will appear below</p>
    <div class="uid-display">
      <div class="uid-val" id="scannedUID">-- -- -- --</div>
      <div class="uid-label">LAST SCANNED UID</div>
    </div>
    <input type="text" id="newName" placeholder="Full Name (e.g. James May)" />
    <button onclick="addUser()">💾 Save User</button>
    <button class="secondary" onclick="copyUID()">📋 Copy UID</button>
  </div>

  <!-- User List -->
  <div class="panel">
    <h2>👥 Authorized Users</h2>
    <div class="user-list" id="userList">Loading...</div>
    <br>
    <button class="secondary" onclick="loadUsers()" style="font-size:11px">↻ Refresh</button>
  </div>

  <!-- WiFi Config -->
  <div class="panel">
    <h2>📶 WiFi Configuration</h2>
    <div id="wifiStatus" style="font-size:12px;line-height:2;margin-bottom:12px">Loading...</div>
    <button onclick="resetWifi()">↺ Reset WiFi &amp; Open Config Portal</button>
    <p style="font-size:10px;color:var(--muted);margin-top:10px">Device will restart and open a WiFi setup hotspot: <b>ToolBox by Layer6</b> — connect and visit <b>192.168.4.1</b> to reconfigure.</p>
  </div>

  <!-- Tool Status -->
  <div class="panel">
    <h2>🔧 Live Tool Status</h2>
    <div id="toolStatus" style="font-size:13px;line-height:2.2">Loading...</div>
  </div>

</div>

<script>
let lastUID = "";

// ── Fetch serial log ──────────────────────────
async function fetchSerial() {
  try {
    const r = await fetch('/api/serial');
    const j = await r.json();
    const mon = document.getElementById('serialMon');
    mon.innerHTML = j.logs.map(l => 
      `<div class="line ${l.includes('ERROR')||l.includes('DENIED')?'warn':''}">&gt; ${l}</div>`
    ).join('');
    mon.scrollTop = mon.scrollHeight;

    // Update last scanned UID
    if (j.lastUID && j.lastUID !== lastUID) {
      lastUID = j.lastUID;
      document.getElementById('scannedUID').textContent = j.lastUID;
    }
  } catch(e) {}
}

// ── Load users ────────────────────────────────
async function loadUsers() {
  const r = await fetch('/api/users');
  const j = await r.json();
  const list = document.getElementById('userList');
  if (!j.users || j.users.length === 0) {
    list.innerHTML = '<p style="color:var(--muted);font-size:12px">No users yet.</p>';
    return;
  }
  list.innerHTML = j.users.map(u => `
    <div class="user-item">
      <div>
        <div class="name">${u.name}</div>
        <div class="uid-small">${u.uid}</div>
      </div>
      <button class="danger" onclick="deleteUser('${u.uid}')" style="padding:6px 12px;font-size:11px">✕</button>
    </div>
  `).join('');
}

// ── Add user ──────────────────────────────────
async function addUser() {
  const uid  = document.getElementById('scannedUID').textContent.trim();
  const name = document.getElementById('newName').value.trim();
  if (uid === '-- -- -- --' || !name) { alert('Scan a card first and enter a name'); return; }
  const r = await fetch('/api/users/add', {
    method: 'POST',
    headers: {'Content-Type':'application/json'},
    body: JSON.stringify({uid, name})
  });
  if (r.ok) {
    document.getElementById('newName').value = '';
    loadUsers();
    alert('User added: ' + name);
  }
}

// ── Delete user ───────────────────────────────
async function deleteUser(uid) {
  if (!confirm('Remove user with UID: ' + uid + '?')) return;
  await fetch('/api/users/delete', {
    method: 'POST',
    headers: {'Content-Type':'application/json'},
    body: JSON.stringify({uid})
  });
  loadUsers();
}

// ── Copy UID ──────────────────────────────────
function copyUID() {
  const uid = document.getElementById('scannedUID').textContent;
  navigator.clipboard.writeText(uid).then(() => alert('Copied: ' + uid));
}

// ── Reset WiFi (triggers WiFiManager config portal) ───────────────
async function resetWifi() {
  if (!confirm('This will restart the device and open the WiFi config portal. Continue?')) return;
  await fetch('/api/wifi/reset', { method: 'POST' });
  alert('Device restarting. Connect to "ToolBox by Layer6" hotspot then open http://192.168.4.1');
}

// ── Fetch device status (IP, WiFi SSID) ───────────────────────────
async function fetchStatus() {
  try {
    const r = await fetch('/api/status');
    const j = await r.json();
    document.getElementById('devIP').textContent = j.ip || '?';
    document.getElementById('wifiStatus').innerHTML =
      `<div>SSID: <b>${j.ssid || 'Not connected'}</b></div>` +
      `<div>IP: <b>${j.ip || 'N/A'}</b></div>` +
      `<div>Signal: <b>${j.rssi ? j.rssi + ' dBm' : 'N/A'}</b></div>`;
  } catch(e) {}
}

// ── Tool status ───────────────────────────────
async function fetchTools() {
  try {
    const r = await fetch('/api/tools');
    const j = await r.json();
    const tools = [
      {name:'Caliper',    key:'caliper'},
      {name:'Plier',      key:'plier'},
      {name:'Micrometer', key:'micrometer'},
      {name:'Tweezer',    key:'tweezer'},
    ];
    document.getElementById('toolStatus').innerHTML = tools.map(t => {
      const taken = j[t.key];
      return `<div style="display:flex;justify-content:space-between;padding:4px 0;border-bottom:1px solid var(--border)">
        <span>${t.name}</span>
        <span class="tag" style="${taken?'background:#2a1a1a;color:var(--warn);border-color:#4a2a2a':''}">
          ${taken ? '🔴 OUT' : '🟢 IN'}
        </span>
      </div>`;
    }).join('');
  } catch(e) {}
}

// ── Auto-refresh ──────────────────────────────
fetchSerial(); loadUsers(); fetchTools(); fetchStatus();
setInterval(fetchSerial, 2000);
setInterval(fetchTools, 3000);
setInterval(fetchStatus, 10000);
</script>
</body>
</html>
)rawhtml";
  server.send(200, "text/html", html);
}

// ─── GET /login ────────────────────────────────────────────────────
void handleLogin() {
  webLog("[WEB] GET /login - Login page requested");
  String html = R"rawhtml(
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>ToolBox Login</title>
<style>
  @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;700&family=Bebas+Neue&display=swap');
  body { background:#0a0a0f; display:flex; align-items:center; justify-content:center; min-height:100vh; font-family:'JetBrains Mono',monospace; }
  .box { background:#12121a; border:1px solid #2a2a3a; border-radius:10px; padding:40px; width:340px; }
  h1 { font-family:'Bebas Neue',sans-serif; color:#00ff9d; letter-spacing:4px; font-size:32px; margin-bottom:6px; }
  p { color:#666680; font-size:11px; margin-bottom:24px; }
  input { width:100%; background:#050508; border:1px solid #2a2a3a; color:#e0e0f0; padding:12px; border-radius:4px; font-family:'JetBrains Mono',monospace; margin:6px 0; font-size:13px; }
  input:focus { outline:none; border-color:#00ff9d; }
  button { width:100%; background:#00ff9d; color:#000; border:none; padding:12px; border-radius:4px; font-weight:700; font-size:13px; letter-spacing:2px; cursor:pointer; margin-top:12px; font-family:'JetBrains Mono',monospace; }
  .err { color:#ff6b35; font-size:11px; margin-top:8px; }
</style>
</head>
<body>
<div class="box">
  <h1>TOOLBOX</h1>
  <p>Admin Access Required</p>
  <input type="text" id="u" placeholder="Username" />
  <input type="password" id="p" placeholder="Password" />
  <button onclick="login()">LOGIN →</button>
  <div class="err" id="err"></div>
</div>
<script>
async function login() {
  const u = document.getElementById('u').value;
  const p = document.getElementById('p').value;
  const r = await fetch('/api/login', {
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body: JSON.stringify({user:u, pass:p})
  });
  if (r.ok) { window.location.href='/'; }
  else { document.getElementById('err').textContent = '✕ Invalid credentials'; }
}
document.addEventListener('keydown', e => { if(e.key==='Enter') login(); });
</script>
</body>
</html>
)rawhtml";
  server.send(200, "text/html", html);
}

// ─── POST /api/login ───────────────────────────────────────────────
void handleApiLogin() {
  if (!server.hasArg("plain")) { server.send(400); return; }
  StaticJsonDocument<128> doc;
  deserializeJson(doc, server.arg("plain"));
  String user = doc["user"].as<String>();
  String pass = doc["pass"].as<String>();
  webLog("[WEB] POST /api/login - Attempt for user: " + user);
  if (user == ADMIN_USER && pass == ADMIN_PASS) {
    server.sendHeader("Set-Cookie", "auth=1; Path=/; Max-Age=86400");
    server.send(200, "application/json", "{\"ok\":true}");
    webLog("[AUTH] ✓ Admin login SUCCESS");
  } else {
    server.send(401, "application/json", "{\"ok\":false}");
    webLog("[AUTH] ✗ Login FAILED for user: " + user);
  }
}

// ─── GET /logout ───────────────────────────────────────────────────
void handleLogout() {
  webLog("[AUTH] Admin logged out");
  server.sendHeader("Set-Cookie", "auth=; Path=/; Max-Age=0");
  server.sendHeader("Location", "/login");
  server.send(302);
}

// ─── GET /api/serial ───────────────────────────────────────────────
void handleApiSerial() {
  if (!isAuthenticated()) { server.send(401); return; }
  // Intentionally NOT using webLog here — would cause infinite self-logging every 2s
  StaticJsonDocument<4096> doc;
  JsonArray arr = doc.createNestedArray("logs");
  // Output in chronological order
  int start = (logCount < LOG_BUFFER_SIZE) ? 0 : logHead;
  for (int i = 0; i < logCount; i++) {
    arr.add(logBuffer[(start + i) % LOG_BUFFER_SIZE]);
  }
  doc["lastUID"] = lastScannedUID;
  String out;
  serializeJson(doc, out);
  server.send(200, "application/json", out);
}

// ─── GET /api/users ────────────────────────────────────────────────
void handleApiUsers() {
  if (!isAuthenticated()) { server.send(401); return; }
  webLog("[WEB] GET /api/users - User list requested");
  server.send(200, "application/json", getAllUsersJSON());
}

// ─── POST /api/users/add ───────────────────────────────────────────
void handleApiAddUser() {
  if (!isAuthenticated()) { server.send(401); return; }
  StaticJsonDocument<256> doc;
  deserializeJson(doc, server.arg("plain"));
  String uid  = doc["uid"].as<String>();
  String name = doc["name"].as<String>();
  if (uid.length() == 0 || name.length() == 0) { server.send(400); return; }
  webLog("[WEB] POST /api/users/add - Adding user via web interface");
  saveUser(uid, name);
  addToKeyIndex(uid);
  server.send(200, "application/json", "{\"ok\":true}");
}

// ─── POST /api/users/delete ────────────────────────────────────────
void handleApiDeleteUser() {
  if (!isAuthenticated()) { server.send(401); return; }
  StaticJsonDocument<128> doc;
  deserializeJson(doc, server.arg("plain"));
  String uid = doc["uid"].as<String>();
  webLog("[WEB] POST /api/users/delete - Deleting user via web interface");
  deleteUser(uid);
  removeFromKeyIndex(uid);
  server.send(200, "application/json", "{\"ok\":true}");
}

// ─── POST /api/wifi/reset ──────────────────────────────────────────
void handleApiWifiReset() {
  if (!isAuthenticated()) { server.send(401); return; }
  webLog("[WiFi] WiFi reset requested — clearing credentials, restarting...");
  server.send(200, "application/json", "{\"ok\":true}");
  delay(500);
  WiFiManager wm;
  wm.resetSettings();
  ESP.restart();
}

// ─── GET /api/status ───────────────────────────────────────────────
void handleApiStatus() {
  if (!isAuthenticated()) { server.send(401); return; }
  StaticJsonDocument<128> doc;
  doc["ip"]   = WiFi.localIP().toString();
  doc["ssid"] = WiFi.SSID();
  doc["rssi"] = WiFi.RSSI();
  String out;
  serializeJson(doc, out);
  server.send(200, "application/json", out);
}

// ─── GET /api/tools ────────────────────────────────────────────────
void handleApiTools() {
  if (!isAuthenticated()) { server.send(401); return; }
  StaticJsonDocument<128> doc;
  doc["caliper"]    = toolCaliper;
  doc["plier"]      = toolPlier;
  doc["micrometer"] = toolMicrometer;
  doc["tweezer"]    = toolTweezer;
  doc["drawer1"]    = drawerOpen;
  String out;
  serializeJson(doc, out);
  server.send(200, "application/json", out);
}

// ═══════════════════════════════════════════════════════════════════
//  SETUP
// ═══════════════════════════════════════════════════════════════════
void setup() {
  Serial.begin(115200);
  webLog("[SYSTEM] ╔═══════════════════════════════════════════╗");
  webLog("[SYSTEM] ║        TOOLBOX INITIALIZING...          ║");
  webLog("[SYSTEM] ╚═══════════════════════════════════════════╝");

  // Pin modes
  webLog("[INIT] Setting up GPIO pins...");
  pinMode(SOLENOID,       OUTPUT);
  pinMode(REED_DRAW1,     INPUT_PULLUP);
  pinMode(BTN_CALIPER,    INPUT_PULLUP);
  pinMode(BTN_PLIER,      INPUT_PULLUP);
  pinMode(BTN_MICROMETER, INPUT_PULLUP);
  pinMode(BTN_TWEEZER,    INPUT_PULLUP);
  digitalWrite(SOLENOID, LOW); // Locked by default
  webLog("[INIT] ✓ GPIO pins configured");

  // Init debounce structs
  btns[0] = {BTN_CALIPER,    false, false, 0};
  btns[1] = {BTN_PLIER,      false, false, 0};
  btns[2] = {BTN_MICROMETER, false, false, 0};
  btns[3] = {BTN_TWEEZER,    false, false, 0};

  // SPI + RFID
  webLog("[INIT] Initializing SPI and RFID...");
  SPI.begin(SPI_SCK, SPI_MISO, SPI_MOSI, SS_PIN);
  rfid.PCD_Init();
  webLog("[INIT] ✓ RFID RC522 initialized");

  // WiFi
  webLog("[INIT] Starting WiFi connection...");
  connectWiFi();

  // Web server routes
  webLog("[INIT] Setting up web server routes...");
  server.on("/",                  HTTP_GET,  handleRoot);
  server.on("/login",             HTTP_GET,  handleLogin);
  server.on("/logout",            HTTP_GET,  handleLogout);
  server.on("/api/login",         HTTP_POST, handleApiLogin);
  server.on("/api/serial",        HTTP_GET,  handleApiSerial);
  server.on("/api/users",         HTTP_GET,  handleApiUsers);
  server.on("/api/users/add",     HTTP_POST, handleApiAddUser);
  server.on("/api/users/delete",  HTTP_POST, handleApiDeleteUser);
  server.on("/api/wifi/reset",    HTTP_POST, handleApiWifiReset);
  server.on("/api/tools",         HTTP_GET,  handleApiTools);
  server.on("/api/status",        HTTP_GET,  handleApiStatus);
  const char* headers[] = {"Cookie"};
  server.collectHeaders(headers, 1);
  server.begin();
  webLog("[INIT] Web server started at http://" + WiFi.localIP().toString());
  webLog("[SYSTEM] ═══════════════════════════════════════════════");
  webLog("[SYSTEM] Ready. Tap a card to access the toolbox...");
}

// ═══════════════════════════════════════════════════════════════════
//  LOOP
// ═══════════════════════════════════════════════════════════════════
void loop() {
  server.handleClient();

  // ── Auto-lock solenoid after timeout ────────────────────────────
  if (solenoidOpenTime > 0 && millis() - solenoidOpenTime > SOLENOID_TIMEOUT) {
    closeSolenoid();
    solenoidOpenTime = 0;
    currentUserName = "";
    currentUserUID  = "";
    webLog("[ACCESS] Session expired — solenoid locked");
  }

  // ── RFID scan ────────────────────────────────────────────────────
  if (rfid.PICC_IsNewCardPresent() && rfid.PICC_ReadCardSerial()) {
    String uid = uidToString(rfid.uid.uidByte, rfid.uid.size);
    lastScannedUID = uid;

    webLog("[SCAN] UID: " + uid);

    String name = getAuthorizedName(uid);
    if (name.length() > 0) {
      webLog("[ACCESS] GRANTED → " + name);
      currentUserName = name;
      currentUserUID  = uid;
      openSolenoid();
    } else {
      webLog("[ACCESS] DENIED → Unknown UID: " + uid);
      currentUserName = "";
      currentUserUID  = "";
    }

    rfid.PICC_HaltA();
    rfid.PCD_StopCrypto1();
  }

  // ── Reed switch: Drawer 1 ────────────────────────────────────────
  // Reed switch: LOW = magnet present = drawer CLOSED, HIGH = no magnet = drawer OPEN
  bool draw1Now = (digitalRead(REED_DRAW1) == HIGH);
  if (draw1Now != drawerOpen) {
    drawerOpen = draw1Now;
    if (drawerOpen) {
      webLog("[DRAWER 1] OPENED by " + (currentUserName.length() ? currentUserName : "Unknown"));
    } else {
      webLog("[DRAWER 1] CLOSED");
    }
  }

  // ── Tool buttons (LOW = pressed = tool taken, with debounce) ─────
  // CALIPER (D0)
  bool calNow = readDebounced(btns[0]);
  if (calNow != toolCaliper) {
    toolCaliper = calNow;
    if (toolCaliper && currentUserName.length() > 0) {
      String ts = getTimestamp();
      webLog("[TOOL] CALIPER - TAKEN by " + currentUserName + " | " + ts);
      logToFirestore(currentUserName, currentUserUID, "Drawer 1", "Caliper", ts, "taken");
    } else if (!toolCaliper) {
      String ts = getTimestamp();
      webLog("[TOOL] CALIPER - RETURNED | " + ts);
      if (currentUserName.length() > 0)
        logToFirestore(currentUserName, currentUserUID, "Drawer 1", "Caliper", ts, "returned");
    }
  }

  // PLIER (D2)
  bool pliNow = readDebounced(btns[1]);
  if (pliNow != toolPlier) {
    toolPlier = pliNow;
    if (toolPlier && currentUserName.length() > 0) {
      String ts = getTimestamp();
      webLog("[TOOL] PLIER - TAKEN by " + currentUserName + " | " + ts);
      logToFirestore(currentUserName, currentUserUID, "Drawer 1", "Plier", ts, "taken");
    } else if (!toolPlier) {
      String ts = getTimestamp();
      webLog("[TOOL] PLIER - RETURNED | " + ts);
      if (currentUserName.length() > 0)
        logToFirestore(currentUserName, currentUserUID, "Drawer 1", "Plier", ts, "returned");
    }
  }

  // MICROMETER (D4)
  bool micNow = readDebounced(btns[2]);
  if (micNow != toolMicrometer) {
    toolMicrometer = micNow;
    if (toolMicrometer && currentUserName.length() > 0) {
      String ts = getTimestamp();
      webLog("[TOOL] MICROMETER - TAKEN by " + currentUserName + " | " + ts);
      logToFirestore(currentUserName, currentUserUID, "Drawer 1", "Micrometer", ts, "taken");
    } else if (!toolMicrometer) {
      String ts = getTimestamp();
      webLog("[TOOL] MICROMETER - RETURNED | " + ts);
      if (currentUserName.length() > 0)
        logToFirestore(currentUserName, currentUserUID, "Drawer 1", "Micrometer", ts, "returned");
    }
  }

  // TWEEZER (D5)
  bool tweNow = readDebounced(btns[3]);
  if (tweNow != toolTweezer) {
    toolTweezer = tweNow;
    if (toolTweezer && currentUserName.length() > 0) {
      String ts = getTimestamp();
      webLog("[TOOL] TWEEZER - TAKEN by " + currentUserName + " | " + ts);
      logToFirestore(currentUserName, currentUserUID, "Drawer 1", "Tweezer", ts, "taken");
    } else if (!toolTweezer) {
      String ts = getTimestamp();
      webLog("[TOOL] TWEEZER - RETURNED | " + ts);
      if (currentUserName.length() > 0)
        logToFirestore(currentUserName, currentUserUID, "Drawer 1", "Tweezer", ts, "returned");
    }
  }
}
