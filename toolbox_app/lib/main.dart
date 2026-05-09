import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';

// ─── Boot ────────────────────────────────────────────────────────────────────

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const ToolBoxApp());
}

// ─── Design Tokens ───────────────────────────────────────────────────────────

class C {
  // Backgrounds
  static const bg       = Color(0xFFF5F0E8);
  static const bgDeep   = Color(0xFFEDE6D9);
  static const card     = Colors.white;

  // Text
  static const ink      = Color(0xFF1C1917);
  static const ink2     = Color(0xFF57534E);
  static const ink3     = Color(0xFFA8A29E);

  // Accent
  static const orange   = Color(0xFFE8772E);
  static const orangeDk = Color(0xFFC2410C);

  // Status
  static const present  = Color(0xFF22C55E);
  static const checkedOut = Color(0xFFF97316);
  static const missing  = Color(0xFFEF4444);

  // Category colors
  static const catElec  = Color(0xFFE8772E);
  static const catPower = Color(0xFFC2410C);
  static const catMeas  = Color(0xFF7C5E2A);
  static const catHand  = Color(0xFF374151);

  // UI
  static const hairline = Color(0x18000000);
  static const shadow   = Color(0x14000000);
}

// ─── Tool Model ──────────────────────────────────────────────────────────────

enum ToolStatus { present, checkedOut, missing }

class AppTool {
  final String id;       // e.g. "C-01"
  final String name;
  final String cat;      // electrical | power | measure | hand
  final Color catColor;
  ToolStatus status;
  String? checkedBy;
  String? since;

  AppTool({
    required this.id,
    required this.name,
    required this.cat,
    required this.catColor,
    this.status = ToolStatus.present,
    this.checkedBy,
    this.since,
  });
}

// Known physical tools
final kTools = [
  AppTool(id: 'A-01', name: 'Caliper',    cat: 'measure',    catColor: C.catMeas),
  AppTool(id: 'A-02', name: 'Plier',      cat: 'hand',       catColor: C.catHand),
  AppTool(id: 'A-03', name: 'Micrometer', cat: 'measure',    catColor: C.catMeas),
  AppTool(id: 'A-04', name: 'Tweezer',    cat: 'electrical', catColor: C.catElec),
];

// ─── Log Model ───────────────────────────────────────────────────────────────

class ToolLog {
  final String id;
  final String userName;
  final String uid;
  final String drawer;
  final String tool;
  final String timestamp;
  final String action;
  final DateTime? createdAt;

  const ToolLog({
    required this.id,
    required this.userName,
    required this.uid,
    required this.drawer,
    required this.tool,
    required this.timestamp,
    required this.action,
    this.createdAt,
  });

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
      userName: d['userName'] as String? ?? '',
      uid: d['uid'] as String? ?? '',
      drawer: d['drawer'] as String? ?? '',
      tool: d['tool'] as String? ?? '',
      timestamp: d['timestamp'] as String? ?? '',
      action: d['action'] as String? ?? 'taken',
      createdAt: createdAt,
    );
  }
}

// ─── ESP32 Service ───────────────────────────────────────────────────────────

class Esp32Service {
  static const _prefKey = 'esp32_ip';
  static const _defaultIp = '192.168.4.1';
  static const _port = 8080;

  Future<String> getIp() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_prefKey) ?? _defaultIp;
  }

  Future<void> setIp(String ip) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_prefKey, ip);
  }

  Future<Map<String, dynamic>?> _get(String path) async {
    try {
      final ip = await getIp();
      final r = await http
          .get(Uri.parse('http://$ip:$_port$path'),
              headers: {'Cookie': 'auth=1'})
          .timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) return jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {}
    return null;
  }

  Future<Map<String, dynamic>?> getToolStatus() => _get('/api/tools');
  Future<Map<String, dynamic>?> getDeviceStatus() => _get('/api/status');
  Future<List<Map<String, dynamic>>> getUsers() async {
    final j = await _get('/api/users');
    if (j == null) return [];
    return List<Map<String, dynamic>>.from(j['users'] ?? []);
  }
}

final _esp = Esp32Service();

// ─── App ─────────────────────────────────────────────────────────────────────

class ToolBoxApp extends StatelessWidget {
  const ToolBoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ToolBox',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: C.bg,
        colorScheme: const ColorScheme.light(
          primary: C.orange,
          surface: C.card,
        ),
        fontFamily: 'Roboto',
        splashFactory: NoSplash.splashFactory,
        highlightColor: Colors.transparent,
      ),
      home: const _MainNav(),
    );
  }
}

// ─── Main Navigation ─────────────────────────────────────────────────────────

class _MainNav extends StatefulWidget {
  const _MainNav();
  @override
  State<_MainNav> createState() => _MainNavState();
}

class _MainNavState extends State<_MainNav> {
  int _i = 0;

  @override
  Widget build(BuildContext context) {
    final screens = [
      const BoxScreen(),
      const ActivityScreen(),
      const MembersScreen(),
    ];

    return Scaffold(
      backgroundColor: C.bg,
      body: IndexedStack(index: _i, children: screens),
      bottomNavigationBar: _BottomTabBar(
        active: _i,
        onChange: (i) => setState(() => _i = i),
      ),
    );
  }
}

// ─── Bottom Tab Bar ───────────────────────────────────────────────────────────

class _BottomTabBar extends StatelessWidget {
  const _BottomTabBar({required this.active, required this.onChange});
  final int active;
  final ValueChanged<int> onChange;

  @override
  Widget build(BuildContext context) {
    const tabs = [
      _TabItem(icon: Icons.inventory_2_outlined, activeIcon: Icons.inventory_2, label: 'Box'),
      _TabItem(icon: Icons.timeline_outlined, activeIcon: Icons.timeline, label: 'Activity'),
      _TabItem(icon: Icons.people_outline, activeIcon: Icons.people, label: 'Members'),
    ];

    return Container(
      decoration: const BoxDecoration(
        color: C.card,
        border: Border(top: BorderSide(color: C.hairline)),
        boxShadow: [BoxShadow(color: C.shadow, blurRadius: 12, offset: Offset(0, -2))],
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 60,
          child: Row(
            children: List.generate(tabs.length, (i) {
              final tab = tabs[i];
              final isActive = i == active;
              return Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChange(i),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isActive ? tab.activeIcon : tab.icon,
                        color: isActive ? C.orange : C.ink3,
                        size: 22,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        tab.label,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                          color: isActive ? C.orange : C.ink3,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _TabItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  const _TabItem({required this.icon, required this.activeIcon, required this.label});
}

// ─── Shared Atoms ────────────────────────────────────────────────────────────

class _ScreenHeader extends StatelessWidget {
  const _ScreenHeader({required this.title, this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: C.bg,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
      child: SafeArea(
        bottom: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 16),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10, fontWeight: FontWeight.w600,
                        color: C.orangeDk, letterSpacing: 1.5,
                      ),
                    ),
                  if (subtitle != null) const SizedBox(height: 4),
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 28, fontWeight: FontWeight.w800,
                      color: C.ink, letterSpacing: -0.5, height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

class _WarmCard extends StatelessWidget {
  const _WarmCard({required this.child, this.padding});
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: C.card,
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [
          BoxShadow(color: Color(0x10000000), blurRadius: 8, offset: Offset(0, 2)),
          BoxShadow(color: Color(0x08000000), blurRadius: 20, offset: Offset(0, 6)),
        ],
      ),
      child: child,
    );
  }
}

// Animated pulsing status dot
class _StatusDot extends StatefulWidget {
  const _StatusDot({required this.status, this.size = 8, this.pulse = false});
  final ToolStatus status;
  final double size;
  final bool pulse;

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot> with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600))
      ..repeat();
    _scale = Tween(begin: 1.0, end: 2.6).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _opacity = Tween(begin: 0.5, end: 0.0).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Color get _color {
    switch (widget.status) {
      case ToolStatus.present:    return C.present;
      case ToolStatus.checkedOut: return C.checkedOut;
      case ToolStatus.missing:    return C.missing;
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.pulse)
            AnimatedBuilder(
              animation: _ctrl,
              builder: (_, __) => Transform.scale(
                scale: _scale.value,
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _color.withOpacity(_opacity.value),
                  ),
                ),
              ),
            ),
          Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(shape: BoxShape.circle, color: _color),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.status});
  final ToolStatus status;

  @override
  Widget build(BuildContext context) {
    final (label, bg, fg) = switch (status) {
      ToolStatus.present    => ('Present',     const Color(0xFFDCFCE7), const Color(0xFF15803D)),
      ToolStatus.checkedOut => ('Checked Out', const Color(0xFFFFF7ED), const Color(0xFFC2410C)),
      ToolStatus.missing    => ('Missing',     const Color(0xFFFEF2F2), const Color(0xFFDC2626)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StatusDot(status: status, size: 6),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(color: fg, fontSize: 10, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

// Colored rounded-square glyph with monospace ID
class _ToolGlyph extends StatelessWidget {
  const _ToolGlyph({required this.tool, this.size = 44});
  final AppTool tool;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(
        color: tool.catColor,
        borderRadius: BorderRadius.circular(size * 0.22),
        boxShadow: [
          BoxShadow(color: tool.catColor.withOpacity(0.3), blurRadius: 6, offset: const Offset(0, 2)),
        ],
      ),
      child: Center(
        child: Text(
          tool.id,
          style: TextStyle(
            fontFamily: 'monospace',
            color: Colors.white,
            fontSize: size * 0.26,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

// Avatar from initials
class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, this.size = 36});
  final String name;
  final double size;

  static const _palette = [
    Color(0xFFE8772E), Color(0xFF0F766E), Color(0xFF7C3AED),
    Color(0xFFBE185D), Color(0xFF1D4ED8), Color(0xFF15803D),
  ];

  String get _initials {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '${parts[0][0]}${parts[parts.length - 1][0]}'.toUpperCase();
  }

  Color get _color => _palette[name.hashCode.abs() % _palette.length];

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: _color),
      child: Center(
        child: Text(
          _initials,
          style: TextStyle(
            color: Colors.white, fontSize: size * 0.36,
            fontWeight: FontWeight.w700, letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}

// Live indicator pill
class _LivePill extends StatelessWidget {
  const _LivePill();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: C.bgDeep,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: C.hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StatusDot(
            status: ToolStatus.present,
            size: 6,
            pulse: true,
          ),
          const SizedBox(width: 5),
          const Text(
            'LIVE',
            style: TextStyle(
              fontFamily: 'monospace', fontSize: 10,
              fontWeight: FontWeight.w700, color: C.ink2, letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Box Screen (Inventory) ───────────────────────────────────────────────────

class BoxScreen extends StatefulWidget {
  const BoxScreen({super.key});
  @override
  State<BoxScreen> createState() => _BoxScreenState();
}

class _BoxScreenState extends State<BoxScreen> {
  bool _gridView = true;
  Map<String, dynamic>? _liveData;
  Timer? _timer;
  bool _deviceOnline = false;

  @override
  void initState() {
    super.initState();
    _pollLive();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _pollLive());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _pollLive() async {
    final data = await _esp.getToolStatus();
    if (mounted) {
      setState(() {
        _liveData = data;
        _deviceOnline = data != null;
      });
    }
  }

  ToolStatus _statusFor(AppTool t, List<ToolLog> logs) {
    // Prefer live ESP32 data
    if (_liveData != null) {
      final key = t.name.toLowerCase();
      if (_liveData!.containsKey(key)) {
        return _liveData![key] == true ? ToolStatus.checkedOut : ToolStatus.present;
      }
    }
    // Fall back to Firestore logs
    final toolLogs = logs.where((l) => l.tool.toLowerCase() == t.name.toLowerCase()).toList();
    if (toolLogs.isEmpty) return ToolStatus.present;
    return toolLogs.first.isTaken ? ToolStatus.checkedOut : ToolStatus.present;
  }

  String? _checkedByFor(AppTool t, List<ToolLog> logs) {
    final toolLogs = logs.where((l) => l.tool.toLowerCase() == t.name.toLowerCase()).toList();
    if (toolLogs.isEmpty) return null;
    return toolLogs.first.isTaken ? toolLogs.first.userName : null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      body: Column(
        children: [
          _ScreenHeader(
            title: 'My Tool Box',
            subtitle: 'TBX',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const _LivePill(),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const SettingsScreen())),
                  child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: C.bgDeep,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: C.hairline),
                    ),
                    child: const Icon(Icons.settings_outlined, color: C.ink2, size: 18),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: C.hairline),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('tool_logs').limit(200).snapshots(),
              builder: (ctx, snap) {
                var logs = snap.hasData
                    ? snap.data!.docs.map(ToolLog.fromFirestore).toList()
                    : <ToolLog>[];
                logs.sort((a, b) {
                  if (a.createdAt == null && b.createdAt == null) return 0;
                  if (a.createdAt == null) return 1;
                  if (b.createdAt == null) return -1;
                  return b.createdAt!.compareTo(a.createdAt!);
                });

                final tools = kTools.map((t) {
                  final copy = AppTool(
                    id: t.id, name: t.name, cat: t.cat, catColor: t.catColor,
                    status: _statusFor(t, logs),
                    checkedBy: _checkedByFor(t, logs),
                  );
                  return copy;
                }).toList();

                final presentCount = tools.where((t) => t.status == ToolStatus.present).length;
                final outCount = tools.where((t) => t.status == ToolStatus.checkedOut).length;

                return RefreshIndicator(
                  color: C.orange,
                  backgroundColor: C.card,
                  onRefresh: _pollLive,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                    children: [
                      // Stats row
                      Row(children: [
                        Expanded(child: _statChip('In Box', '$presentCount', C.present)),
                        const SizedBox(width: 10),
                        Expanded(child: _statChip('Checked Out', '$outCount', C.checkedOut)),
                        const SizedBox(width: 10),
                        Expanded(child: _statChip('Device', _deviceOnline ? 'On' : 'Off',
                            _deviceOnline ? C.present : C.ink3)),
                      ]),
                      const SizedBox(height: 16),

                      // View toggle
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '${tools.length} tools',
                            style: const TextStyle(
                                fontFamily: 'monospace', fontSize: 11,
                                color: C.ink3, letterSpacing: 0.5),
                          ),
                          Container(
                            decoration: BoxDecoration(
                              color: C.bgDeep,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              _viewToggleBtn(Icons.grid_view, true),
                              _viewToggleBtn(Icons.view_list, false),
                            ]),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      // Tool grid or list
                      if (_gridView)
                        GridView.count(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          crossAxisCount: 2,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 1.05,
                          children: tools.map((t) => _ToolGridCard(tool: t)).toList(),
                        )
                      else
                        ...tools.map((t) => Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _ToolListCard(tool: t),
                        )),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _statChip(String label, String value, Color color) {
    return _WarmCard(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value, style: TextStyle(
              fontSize: 22, fontWeight: FontWeight.w800, color: color, height: 1)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 10, color: C.ink3)),
        ],
      ),
    );
  }

  Widget _viewToggleBtn(IconData icon, bool isGrid) {
    final active = _gridView == isGrid;
    return GestureDetector(
      onTap: () => setState(() => _gridView = isGrid),
      child: Container(
        width: 34, height: 30,
        decoration: BoxDecoration(
          color: active ? C.card : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
          boxShadow: active ? [const BoxShadow(color: C.shadow, blurRadius: 4)] : null,
        ),
        child: Icon(icon, size: 16, color: active ? C.orange : C.ink3),
      ),
    );
  }
}

// Tool card — grid style
class _ToolGridCard extends StatelessWidget {
  const _ToolGridCard({required this.tool});
  final AppTool tool;

  @override
  Widget build(BuildContext context) {
    return _WarmCard(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _ToolGlyph(tool: tool, size: 40),
              _StatusDot(
                status: tool.status,
                size: 9,
                pulse: tool.status == ToolStatus.present,
              ),
            ],
          ),
          const Spacer(),
          Text(
            tool.name,
            style: const TextStyle(
                fontSize: 14, fontWeight: FontWeight.w700, color: C.ink, height: 1.2),
          ),
          const SizedBox(height: 4),
          _StatusPill(status: tool.status),
          if (tool.checkedBy != null) ...[
            const SizedBox(height: 4),
            Text(
              tool.checkedBy!,
              style: const TextStyle(fontSize: 10, color: C.ink3),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

// Tool card — list style
class _ToolListCard extends StatelessWidget {
  const _ToolListCard({required this.tool});
  final AppTool tool;

  @override
  Widget build(BuildContext context) {
    return _WarmCard(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          _ToolGlyph(tool: tool, size: 44),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tool.name,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w700, color: C.ink)),
                const SizedBox(height: 3),
                Text(
                  tool.cat[0].toUpperCase() + tool.cat.substring(1),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: C.ink3),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _StatusPill(status: tool.status),
              if (tool.checkedBy != null) ...[
                const SizedBox(height: 4),
                Text(tool.checkedBy!,
                    style: const TextStyle(fontSize: 10, color: C.ink3)),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Activity Screen ──────────────────────────────────────────────────────────

class ActivityScreen extends StatefulWidget {
  const ActivityScreen({super.key});
  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  String _filter = 'All';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      body: Column(
        children: [
          _ScreenHeader(title: 'Activity', subtitle: 'HISTORY'),
          // Filter chips
          Container(
            color: C.bg,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: ['All', 'Taken', 'Returned'].map((opt) {
                  final active = _filter == opt;
                  return GestureDetector(
                    onTap: () => setState(() => _filter = opt),
                    child: Container(
                      margin: const EdgeInsets.only(right: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: active ? C.orange : C.bgDeep,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: active ? C.orange : C.hairline,
                        ),
                      ),
                      child: Text(
                        opt,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: active ? Colors.white : C.ink2,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),
          const Divider(height: 1, color: C.hairline),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('tool_logs').limit(200).snapshots(),
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(
                      child: CircularProgressIndicator(color: C.orange));
                }
                var logs = snap.hasData
                    ? snap.data!.docs.map(ToolLog.fromFirestore).toList()
                    : <ToolLog>[];
                logs.sort((a, b) {
                  if (a.createdAt == null && b.createdAt == null) return 0;
                  if (a.createdAt == null) return 1;
                  if (b.createdAt == null) return -1;
                  return b.createdAt!.compareTo(a.createdAt!);
                });

                if (_filter == 'Taken')    logs = logs.where((l) => l.isTaken).toList();
                if (_filter == 'Returned') logs = logs.where((l) => !l.isTaken).toList();

                if (logs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 56, height: 56,
                          decoration: BoxDecoration(
                            color: C.bgDeep, borderRadius: BorderRadius.circular(14),
                          ),
                          child: const Icon(Icons.timeline, color: C.ink3, size: 28),
                        ),
                        const SizedBox(height: 14),
                        const Text('No events', style: TextStyle(color: C.ink3, fontSize: 15)),
                      ],
                    ),
                  );
                }

                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                  itemCount: logs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _ActivityTile(log: logs[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ActivityTile extends StatelessWidget {
  const _ActivityTile({required this.log});
  final ToolLog log;

  @override
  Widget build(BuildContext context) {
    final isTaken = log.isTaken;
    final accentColor = isTaken ? C.checkedOut : C.present;

    return _WarmCard(
      padding: EdgeInsets.zero,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: IntrinsicHeight(
          child: Row(
            children: [
              Container(width: 4, color: accentColor),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      _Avatar(name: log.userName, size: 38),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  log.tool,
                                  style: TextStyle(
                                    fontFamily: 'monospace', fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: accentColor, letterSpacing: 0.5,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: isTaken
                                        ? const Color(0xFFFFF7ED)
                                        : const Color(0xFFDCFCE7),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    isTaken ? 'TAKEN' : 'RETURNED',
                                    style: TextStyle(
                                      fontSize: 9, fontWeight: FontWeight.w700,
                                      color: accentColor,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 3),
                            Text(
                              log.userName.isEmpty ? 'Unknown' : log.userName,
                              style: const TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w700, color: C.ink),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${log.drawer}  ·  ${log.timestamp}',
                              style: const TextStyle(fontSize: 10, color: C.ink3),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        isTaken ? Icons.outbox_outlined : Icons.move_to_inbox_outlined,
                        color: accentColor, size: 18,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Members Screen ───────────────────────────────────────────────────────────

class MembersScreen extends StatefulWidget {
  const MembersScreen({super.key});
  @override
  State<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends State<MembersScreen> {
  List<Map<String, dynamic>> _users = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final users = await _esp.getUsers();
    if (mounted) setState(() { _users = users; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      body: Column(
        children: [
          _ScreenHeader(title: 'Members', subtitle: 'RFID USERS'),
          const Divider(height: 1, color: C.hairline),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('tool_logs').limit(200).snapshots(),
              builder: (ctx, snap) {
                final logs = snap.hasData
                    ? snap.data!.docs.map(ToolLog.fromFirestore).toList()
                    : <ToolLog>[];

                // Compute active tools per user
                final activeByUser = <String, int>{};
                final latestByKey = <String, ToolLog>{};
                for (final l in logs.reversed) {
                  final key = '${l.userName}_${l.tool}';
                  latestByKey[key] = l;
                }
                for (final l in latestByKey.values) {
                  if (l.isTaken) {
                    activeByUser[l.userName] = (activeByUser[l.userName] ?? 0) + 1;
                  }
                }

                if (_loading) {
                  return const Center(child: CircularProgressIndicator(color: C.orange));
                }

                if (_users.isEmpty) {
                  return RefreshIndicator(
                    color: C.orange,
                    backgroundColor: C.card,
                    onRefresh: _load,
                    child: ListView(
                      children: [
                        const SizedBox(height: 80),
                        Center(
                          child: Column(
                            children: [
                              Container(
                                width: 64, height: 64,
                                decoration: BoxDecoration(
                                  color: C.bgDeep, borderRadius: BorderRadius.circular(16),
                                ),
                                child: const Icon(Icons.people_outline, color: C.ink3, size: 32),
                              ),
                              const SizedBox(height: 16),
                              const Text('No members found',
                                  style: TextStyle(color: C.ink2, fontSize: 15, fontWeight: FontWeight.w600)),
                              const SizedBox(height: 6),
                              const Text(
                                'Add users via the ESP32 web admin panel',
                                style: TextStyle(color: C.ink3, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return RefreshIndicator(
                  color: C.orange,
                  backgroundColor: C.card,
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                    itemCount: _users.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      final u = _users[i];
                      final name = u['name'] as String? ?? '—';
                      final uid = u['uid'] as String? ?? '—';
                      final active = activeByUser[name] ?? 0;
                      return _WarmCard(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            _Avatar(name: name, size: 44),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(name, style: const TextStyle(
                                      fontSize: 15, fontWeight: FontWeight.w700, color: C.ink)),
                                  const SizedBox(height: 3),
                                  Text(
                                    'UID: $uid',
                                    style: const TextStyle(
                                        fontFamily: 'monospace', fontSize: 10, color: C.ink3),
                                  ),
                                ],
                              ),
                            ),
                            if (active > 0)
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFF7ED),
                                  borderRadius: BorderRadius.circular(999),
                                  border: Border.all(color: const Color(0xFFFED7AA)),
                                ),
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                  const Icon(Icons.outbox_outlined, size: 12, color: C.orangeDk),
                                  const SizedBox(width: 4),
                                  Text('$active out', style: const TextStyle(
                                      fontSize: 11, fontWeight: FontWeight.w700, color: C.orangeDk)),
                                ]),
                              )
                            else
                              const Icon(Icons.nfc, color: C.ink3, size: 20),
                          ],
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Settings Screen ──────────────────────────────────────────────────────────

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _ipCtrl = TextEditingController();
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    _esp.getIp().then((ip) { if (mounted) _ipCtrl.text = ip; });
  }

  @override
  void dispose() {
    _ipCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final ip = _ipCtrl.text.trim();
    if (ip.isEmpty) return;
    await _esp.setIp(ip);
    if (mounted) setState(() => _saved = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _saved = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: C.bg,
      appBar: AppBar(
        backgroundColor: C.bg,
        elevation: 0,
        leading: GestureDetector(
          onTap: () => Navigator.pop(context),
          child: const Icon(Icons.arrow_back, color: C.ink),
        ),
        title: const Text('Settings',
            style: TextStyle(color: C.ink, fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionLabel('ESP32 LOCAL API'),
          const SizedBox(height: 10),
          _WarmCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Device IP Address',
                    style: TextStyle(color: C.ink, fontSize: 14, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                const Text(
                  'Enter the IP shown on the web admin panel or serial monitor.',
                  style: TextStyle(color: C.ink3, fontSize: 11, height: 1.4),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: _ipCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: C.ink, fontSize: 14),
                  decoration: InputDecoration(
                    hintText: '192.168.1.xxx',
                    hintStyle: const TextStyle(color: C.ink3),
                    prefixText: 'http://',
                    prefixStyle: const TextStyle(color: C.ink3, fontSize: 13),
                    suffixText: ':8080',
                    suffixStyle: const TextStyle(color: C.ink3, fontSize: 13),
                    filled: true,
                    fillColor: C.bgDeep,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: C.hairline),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: C.hairline),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: C.orange),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: _save,
                    style: FilledButton.styleFrom(
                      backgroundColor: _saved ? C.present : C.orange,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Text(
                      _saved ? 'Saved!' : 'Save IP',
                      style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 0.5),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          _sectionLabel('FIREBASE'),
          const SizedBox(height: 10),
          _WarmCard(
            child: Column(children: [
              _settingRow('Project', 'smart-toolbox-b0455'),
              const Divider(height: 20, color: C.hairline),
              _settingRow('Collection', 'tool_logs'),
              const Divider(height: 20, color: C.hairline),
              _settingRow('Stream', 'Real-time via SDK'),
            ]),
          ),
          const SizedBox(height: 24),
          _sectionLabel('HOW TO CONNECT'),
          const SizedBox(height: 10),
          _WarmCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                _HelpStep('1', 'Connect phone to the same WiFi as the ESP32'),
                _HelpStep('2', 'Find device IP from serial monitor or web admin'),
                _HelpStep('3', 'Enter IP above and tap Save'),
                _HelpStep('4', 'Tool status will update live on the Box tab'),
                SizedBox(height: 4),
                Text(
                  'AP mode: connect to "ToolBox by Layer6" hotspot, use IP 192.168.4.1',
                  style: TextStyle(color: C.ink3, fontSize: 11, height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(
    text,
    style: const TextStyle(
      fontFamily: 'monospace', fontSize: 10, fontWeight: FontWeight.w600,
      color: C.ink3, letterSpacing: 1.5,
    ),
  );

  Widget _settingRow(String label, String value) => Row(children: [
    Text(label, style: const TextStyle(color: C.ink2, fontSize: 12)),
    const Spacer(),
    Text(value, style: const TextStyle(color: C.ink, fontSize: 12, fontWeight: FontWeight.w700)),
  ]);
}

class _HelpStep extends StatelessWidget {
  const _HelpStep(this.num, this.text);
  final String num;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20, height: 20,
            decoration: BoxDecoration(
              color: C.orange.withOpacity(0.12),
              shape: BoxShape.circle,
              border: Border.all(color: C.orange.withOpacity(0.4)),
            ),
            child: Center(
              child: Text(num, style: const TextStyle(
                  color: C.orange, fontSize: 10, fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: const TextStyle(color: C.ink2, fontSize: 12, height: 1.4)),
          ),
        ],
      ),
    );
  }
}
