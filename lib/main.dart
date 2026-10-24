```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:battery_plus/battery_plus.dart' show Battery, BatteryState;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:gal/gal.dart' show Gal;
import 'package:mobile_scanner/mobile_scanner.dart'
    show BarcodeCapture, BarcodeFormat, MobileScanner, MobileScannerController;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart' show QrImageView, QrVersions;
import 'package:wakelock_plus/wakelock_plus.dart';

const int kPort = 8080;
const int kWakePort = 8081; // standby listener (camera app closed)
// LAN only by default; applyNetConfig() adds STUN in "outside the LAN" mode.
Map<String, dynamic> kPcConfig = {
  'sdpSemantics': 'unified-plan',
  'iceServers': <Map<String, dynamic>>[],
};

const MethodChannel _svc = MethodChannel('lancam/service');
const EventChannel _screenEvents = EventChannel('lancam/screen');

// ── design tokens ──
const Color kBg = Color(0xFF0B1220);
const Color kSurface = Color(0xFF111B2E);
const Color kSurface2 = Color(0xFF1B2A44);
const Color kAccent = Color(0xFF22D3EE);
const Color kRed = Color(0xFFEF4444);
const Color kGreen = Color(0xFF22C55E);

void main() => runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'LAN Cam',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme:
            ColorScheme.fromSeed(seedColor: kAccent, brightness: Brightness.dark),
        scaffoldBackgroundColor: kBg,
        appBarTheme: const AppBarTheme(
          backgroundColor: kBg,
          elevation: 0,
          centerTitle: true,
          scrolledUnderElevation: 0,
        ),
      ),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const Home(),
    ));

// ───────────────────────────── Helpers ─────────────────────────────
Future<void> _portrait() async {
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
}

Future<void> _landscape({bool immersive = false}) async {
  await SystemChrome.setPreferredOrientations(
      [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
  if (immersive) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }
}

String _newPin() => (100000 + Random().nextInt(900000)).toString();

Future<File> _settingsFile() async =>
    File('${(await getApplicationDocumentsDirectory()).path}/settings.json');

Future<Map<String, dynamic>> loadSettings() async {
  try {
    final f = await _settingsFile();
    if (await f.exists()) {
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    }
  } catch (_) {}
  return {};
}

Future<void> saveSettings(Map<String, dynamic> patch) async {
  try {
    final m = await loadSettings();
    m.addAll(patch);
    await (await _settingsFile()).writeAsString(jsonEncode(m));
  } catch (_) {}
}

/// This phone's Wi-Fi / hotspot IPv4 address.
Future<String?> localIp() async {
  String? fallback;
  final wifi = RegExp(r'^(wlan|swlan|ap|en|bridge)\d*$');
  for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
    for (final a in i.addresses) {
      if (a.isLoopback || a.isLinkLocal) continue;
      if (wifi.hasMatch(i.name)) return a.address;
      fallback ??= a.address;
    }
  }
  return fallback;
}

/// Scan the local /24 network for LAN Cam cameras (no typing needed).
Future<List<String>> scanLan() async {
  final mine = await localIp();
  if (mine == null) return [];
  final p = mine.split('.');
  final base = '${p[0]}.${p[1]}.${p[2]}';
  final found = <String>[];

  Future<void> probe(int n) async {
    final ip = '$base.$n';
    if (ip == mine) return;
    try {
      final s = await Socket.connect(ip, kPort,
          timeout: const Duration(milliseconds: 700));
      s.destroy();
      final c = HttpClient()
        ..connectionTimeout = const Duration(milliseconds: 800);
      final req = await c
          .getUrl(Uri.parse('http://$ip:$kPort/'))
          .timeout(const Duration(seconds: 2));
      final res = await req.close().timeout(const Duration(seconds: 2));
      final body = await res
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 2));
      c.close(force: true);
      if (body.startsWith('LAN Cam')) {
        found.add(ip);
        return;
      }
    } catch (_) {}
    // Camera in standby (app closed): only the wake port is open.
    try {
      final s = await Socket.connect(ip, kWakePort,
          timeout: const Duration(milliseconds: 700));
      s.destroy();
      found.add(ip);
    } catch (_) {}
  }

  for (var start = 1; start <= 254; start += 64) {
    await Future.wait([
      for (var n = start; n < start + 64 && n <= 254; n++) probe(n),
    ]);
  }
  return found;
}

/// Wait until ICE candidates are gathered (non-trickle signaling).
Future<void> waitIceGathered(RTCPeerConnection pc) async {
  if (pc.iceGatheringState ==
      RTCIceGatheringState.RTCIceGatheringStateComplete) return;
  final c = Completer<void>();
  pc.onIceGatheringState = (s) {
    if (s == RTCIceGatheringState.RTCIceGatheringStateComplete &&
        !c.isCompleted) c.complete();
  };
  await c.future.timeout(const Duration(seconds: 3), onTimeout: () {});
}

/// Network options. STUN servers are added only in "outside the LAN" mode.
Future<void> applyNetConfig() async {
  final s = await loadSettings();
  final wan = (s['wan'] as bool?) ?? false;
  kPcConfig = {
    'sdpSemantics': 'unified-plan',
    'iceServers': wan
        ? <Map<String, dynamic>>[
            {'urls': 'stun:stun.l.google.com:19302'},
            {'urls': 'stun:stun1.l.google.com:19302'},
          ]
        : <Map<String, dynamic>>[],
  };
}

double numOf(dynamic v) => v is num ? v.toDouble() : (double.tryParse('$v') ?? 0);

String two(int n) => n.toString().padLeft(2, '0');

String fmtStamp(DateTime t) =>
    '${t.year}-${two(t.month)}-${two(t.day)}  ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';

String fmtFile(DateTime t) =>
    '${t.year}-${two(t.month)}-${two(t.day)}_${two(t.hour)}-${two(t.minute)}-${two(t.second)}';

String srtTime(int ms) {
  final h = ms ~/ 3600000;
  final m = (ms ~/ 60000) % 60;
  final s = (ms ~/ 1000) % 60;
  final r = ms % 1000;
  return '${two(h)}:${two(m)}:${two(s)},${r.toString().padLeft(3, '0')}';
}

/// Every IPv4 address of this phone with its interface name (Wi-Fi, VPN...).
Future<List<MapEntry<String, String>>> allIps() async {
  final out = <MapEntry<String, String>>[];
  try {
    for (final i
        in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      for (final a in i.addresses) {
        if (a.isLoopback || a.isLinkLocal) continue;
        out.add(MapEntry(i.name, a.address));
      }
    }
  } catch (_) {}
  return out;
}

Future<bool> portOpen(String ip, int port) async {
  try {
    final s = await Socket.connect(ip, port,
        timeout: const Duration(milliseconds: 1200));
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

/// 'ok' | 'unreachable' | 'denied' | 'noreply'
Future<String> wakeCamera(String ip, String pin) async {
  Socket s;
  try {
    s = await Socket.connect(ip, kWakePort,
        timeout: const Duration(seconds: 3));
  } catch (_) {
    return 'unreachable';
  }
  try {
    s.write('WAKE:$pin\n');
    await s.flush();
    final reply = await s
        .cast<List<int>>()
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 5), onTimeout: () => '');
    s.destroy();
    final r = reply.trim();
    if (r == 'OK') return 'ok';
    if (r == 'DENIED') return 'denied';
    return 'noreply';
  } catch (_) {
    return 'noreply';
  }
}

const List<String> kQualityNames = [
  'عالية',
  'جيدة',
  'متوسطة',
  'منخفضة',
  'دنيا'
];

/// Date + time stamp shown over the video.
class ClockStamp extends StatelessWidget {
  const ClockStamp({super.key, required this.time});
  final ValueListenable<DateTime> time;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<DateTime>(
        valueListenable: time,
        builder: (_, t, __) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0x99000000),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(fmtStamp(t),
              textDirection: TextDirection.ltr,
              style: const TextStyle(
                  fontSize: 11, color: Colors.white, letterSpacing: 0.4)),
        ),
      );
}

/// Camera health (battery / temperature / Wi-Fi) + link quality chips.
class HealthBar extends StatelessWidget {
  const HealthBar({super.key, required this.h, this.link = ''});
  final Map h;
  final String link; // '', good, fair, poor (measured on the viewer)

  Widget _chip(IconData icon, String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: const Color(0x99000000),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: c),
          const SizedBox(width: 4),
          Text(text,
              textDirection: TextDirection.ltr,
              style: const TextStyle(fontSize: 11, color: Colors.white)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final bat = h['bat'];
    final chg = h['chg'] == true;
    final temp = h['temp'];
    final rssi = h['rssi'];
    final q = h['q'];
    final chips = <Widget>[];
    if (bat is num) {
      final low = bat <= 20 && !chg;
      chips.add(_chip(
          chg
              ? Icons.battery_charging_full_rounded
              : (low ? Icons.battery_alert_rounded : Icons.battery_full_rounded),
          '${bat.toInt()}%',
          low ? kRed : (chg ? kGreen : Colors.white70)));
    }
    if (temp is num) {
      chips.add(_chip(Icons.thermostat_rounded, '${temp.toStringAsFixed(0)}°',
          temp >= 45 ? kRed : (temp >= 41 ? Colors.amber : Colors.white70)));
    }
    if (rssi is num) {
      chips.add(_chip(Icons.wifi_rounded, '${rssi.toInt()} dBm',
          rssi <= -80 ? kRed : (rssi <= -70 ? Colors.amber : kGreen)));
    }
    if (link.isNotEmpty) {
      final c = link == 'good'
          ? kGreen
          : (link == 'fair' ? Colors.amber : kRed);
      final t = link == 'good' ? 'اتصال قوي' : (link == 'fair' ? 'متوسط' : 'ضعيف');
      chips.add(_chip(Icons.network_check_rounded, t, c));
    }
    if (q is num && q > 0) {
      chips.add(_chip(Icons.speed_rounded,
          'جودة تلقائية: ${kQualityNames[q.toInt().clamp(0, 4).toInt()]}', Colors.amber));
    }
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(spacing: 5, runSpacing: 5, children: chips);
  }
}

/// Scans a LAN Cam pairing QR code. Pops with the raw text.
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});
  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final _c = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _done = false;

  void _onDetect(BarcodeCapture cap) {
    if (_done) return;
    for (final b in cap.barcodes) {
      final v = b.rawValue;
      if (v != null && v.startsWith('LANCAM|')) {
        _done = true;
        Navigator.pop(context, v);
        return;
      }
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('امسح رمز QR من شاشة الكاميرا')),
        body: Stack(fit: StackFit.expand, children: [
          MobileScanner(controller: _c, onDetect: _onDetect),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: kAccent, width: 3),
                borderRadius: BorderRadius.circular(22),
              ),
            ),
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 40,
            child: Text('على جهاز الكاميرا اضغط "عرض رمز QR"',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70)),
          ),
        ]),
      );
}

// ───────────────────────────── Widgets ─────────────────────────────
class LogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final rect = Offset.zero & size;
    canvas.save();
    canvas.clipRRect(RRect.fromRectAndRadius(rect, Radius.circular(s * 0.225)));
    canvas.drawRect(
        rect,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0B1220), Color(0xFF12304A)],
          ).createShader(rect));
    final c = Offset(s * 0.46, s * 0.56);
    canvas.drawCircle(
        c,
        s * 0.6,
        Paint()
          ..shader = const RadialGradient(
            colors: [Color(0x4722D3EE), Color(0x0022D3EE)],
          ).createShader(Rect.fromCircle(center: c, radius: s * 0.6)));
    canvas.drawCircle(
        c,
        s * 0.225,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF22D3EE), Color(0xFF2563EB)],
          ).createShader(Rect.fromCircle(center: c, radius: s * 0.225)));
    canvas.drawCircle(c, s * 0.185, Paint()..color = const Color(0xFF0A1628));
    canvas.drawCircle(
        c,
        s * 0.15,
        Paint()
          ..shader = const RadialGradient(
            center: Alignment(-0.3, -0.3),
            colors: [Color(0xFF3B82F6), Color(0xFF0B1B3A)],
          ).createShader(Rect.fromCircle(center: c, radius: s * 0.15)));
    canvas.drawCircle(c, s * 0.068, Paint()..color = const Color(0xFF050B18));
    canvas.drawCircle(c.translate(-s * 0.05, -s * 0.055), s * 0.03,
        Paint()..color = const Color(0x99FFFFFF));
    canvas.restore();

    const colors = [Color(0xFF22D3EE), Color(0xBF22D3EE), Color(0x8022D3EE)];
    const radii = [0.30, 0.36, 0.42];
    for (var i = 0; i < 3; i++) {
      canvas.drawArc(
          Rect.fromCircle(center: c, radius: s * radii[i]),
          -70 * pi / 180,
          50 * pi / 180,
          false,
          Paint()
            ..color = colors[i]
            ..style = PaintingStyle.stroke
            ..strokeWidth = s * 0.026
            ..strokeCap = StrokeCap.round);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class LogoMark extends StatelessWidget {
  const LogoMark({super.key, this.size = 96});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.225),
          boxShadow: const [BoxShadow(color: Color(0x3322D3EE), blurRadius: 36)],
        ),
        child: CustomPaint(painter: LogoPainter()),
      );
}

class Pill extends StatelessWidget {
  const Pill({super.key, required this.color, required this.text});
  final Color color;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0x99000000),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(text,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8)),
        ]),
      );
}

class RoundIcon extends StatelessWidget {
  const RoundIcon({super.key, required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0x99000000),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(icon, color: Colors.white, size: 20),
          ),
        ),
      );
}

class InfoRow extends StatelessWidget {
  const InfoRow({
    super.key,
    required this.label,
    required this.value,
    this.big = false,
    this.trailing,
  });
  final String label;
  final String value;
  final bool big;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: BoxDecoration(
          color: kBg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label,
                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
              const SizedBox(height: 2),
              Directionality(
                textDirection: TextDirection.ltr,
                child: SelectableText(value,
                    style: TextStyle(
                        fontSize: big ? 26 : 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: big ? 4 : 0.5)),
              ),
            ]),
          ),
          if (trailing != null) trailing!,
          IconButton(
            icon: const Icon(Icons.copy_rounded, size: 18),
            color: Colors.white54,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content: Text('تم النسخ'), duration: Duration(seconds: 1)));
            },
          ),
        ]),
      );
}

class CtlButton extends StatelessWidget {
  const CtlButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = false,
    this.dark = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final bg = active
        ? kRed
        : (dark ? const Color(0x33FFFFFF) : kSurface2);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Material(
        color: bg,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 50,
            height: 50,
            child: Icon(icon, color: Colors.white, size: 24),
          ),
        ),
      ),
      const SizedBox(height: 4),
      Text(label,
          style: const TextStyle(fontSize: 11, color: Colors.white70)),
    ]);
  }
}

/// In-app numeric keypad WITH a dot key (works on every phone/locale).
class Keypad extends StatelessWidget {
  const Keypad({super.key, required this.onKey, required this.onBack});
  final void Function(String) onKey;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '.', '0', '⌫'];
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 10),
        child: GridView.count(
          crossAxisCount: 3,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 2.6,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: [
            for (final k in keys)
              Material(
                color: kSurface2,
                borderRadius: BorderRadius.circular(14),
                child: InkWell(
                  borderRadius: BorderRadius.circular(14),
                  onTap: () => k == '⌫' ? onBack() : onKey(k),
                  child: Center(
                    child: k == '⌫'
                        ? const Icon(Icons.backspace_outlined,
                            color: Colors.white70)
                        : Text(k,
                            style: const TextStyle(
                                fontSize: 24, fontWeight: FontWeight.w600)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class ModeCard extends StatelessWidget {
  const ModeCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.tint,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final Color tint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(22),
          onTap: onTap,
          child: Ink(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: Colors.white10),
            ),
            child: Row(children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: tint,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, color: color, size: 30),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 3),
                      Text(subtitle,
                          style: const TextStyle(
                              fontSize: 13, color: Colors.white60)),
                    ]),
              ),
              const Icon(Icons.chevron_left_rounded,
                  color: Colors.white38, size: 28),
            ]),
          ),
        ),
      );
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkAutostart();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkAutostart();
  }

  /// A viewer woke this phone (app was closed): open the camera by itself.
  Future<void> _checkAutostart() async {
    if (!Platform.isAndroid) return;
    try {
      final go = await _svc.invokeMethod<bool>('consumeAutostart');
      if (go == true && !CameraPage.active && mounted) {
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => const CameraPage(autoMinimize: true)));
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF0F2038), kBg],
            ),
          ),
          child: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 520),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const LogoMark(size: 116),
                    const SizedBox(height: 20),
                    const Text('LAN Cam',
                        style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.5)),
                    const SizedBox(height: 6),
                    const Text('مراقبة خاصة عبر شبكتك المحلية',
                        style: TextStyle(color: Colors.white60, fontSize: 15)),
                    const SizedBox(height: 34),
                    ModeCard(
                      icon: Icons.videocam_rounded,
                      title: 'وضع الكاميرا',
                      subtitle: 'حوّل هذا الهاتف إلى كاميرا مراقبة',
                      color: kAccent,
                      tint: const Color(0x2622D3EE),
                      onTap: () => Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const CameraPage())),
                    ),
                    const SizedBox(height: 14),
                    ModeCard(
                      icon: Icons.visibility_rounded,
                      title: 'وضع المشاهدة',
                      subtitle: 'شاهد البث واتحكم بالكاميرا عن بعد',
                      color: const Color(0xFFA78BFA),
                      tint: const Color(0x26A78BFA),
                      onTap: () => Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const ViewerPage())),
                    ),
                    const SizedBox(height: 14),
                    ModeCard(
                      icon: Icons.grid_view_rounded,
                      title: 'عدة كاميرات',
                      subtitle: 'شاهد حتى 4 كاميرات معاً في شبكة 2×2',
                      color: const Color(0xFFF472B6),
                      tint: const Color(0x26F472B6),
                      onTap: () => Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const MultiViewPage())),
                    ),
                    const SizedBox(height: 14),
                    ModeCard(
                      icon: Icons.phone_android_rounded,
                      title: 'شاشة الهاتف',
                      subtitle: 'اعرض شاشة هاتف آخر وتحكم به عن بعد',
                      color: const Color(0xFF34D399),
                      tint: const Color(0x2634D399),
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const ViewerPage(screen: true))),
                    ),
                    const SizedBox(height: 14),
                    ModeCard(
                      icon: Icons.tune_rounded,
                      title: 'إعدادات البث',
                      subtitle: 'الدقة، الإطارات، معدل البيانات وغيرها',
                      color: const Color(0xFFFBBF24),
                      tint: const Color(0x26FBBF24),
                      onTap: () => Navigator.push(context,
                          MaterialPageRoute(builder: (_) => const SettingsPage())),
                    ),
                    const SizedBox(height: 28),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final f in const [
                          'بث مباشر',
                          'صوت ثنائي الاتجاه',
                          'تسجيل',
                          'رمز حماية PIN',
                          'ربط QR',
                          'رؤية ليلية',
                          'إعادة اتصال تلقائية',
                        ])
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: Colors.white12),
                            ),
                            child: Text(f,
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.white60)),
                          ),
                      ],
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
}

// ───────────────────────────── Settings ─────────────────────────────
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Map<String, dynamic> _s = {};

  @override
  void initState() {
    super.initState();
    loadSettings().then((m) {
      if (mounted) setState(() => _s = m);
    });
  }

  void _set(String k, Object v) {
    setState(() => _s[k] = v);
    saveSettings({k: v});
  }

  Widget _chips<T>(String label, String key, T def, List<T> values,
      List<String> labels) {
    final cur = _s[key] is T ? _s[key] as T : def;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label,
            style: const TextStyle(fontSize: 13, color: Colors.white70)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (var i = 0; i < values.length; i++)
            ChoiceChip(
              label: Text(labels[i]),
              selected: values[i] == cur,
              onSelected: (_) => _set(key, values[i] as Object),
            ),
        ]),
      ]),
    );
  }

  Widget _group(String title, IconData icon, List<Widget> children) =>
      Container(
        margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 2),
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: kAccent, size: 20),
            const SizedBox(width: 8),
            Text(title,
                style:
                    const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(height: 14),
          ...children,
        ]),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('إعدادات البث')),
        body: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
          _group('البث (جهاز الكاميرا)', Icons.videocam_rounded, [
            _chips<int>('الدقة', 'res', 720, [360, 480, 720, 1080],
                ['360p', '480p', '720p HD', '1080p FHD']),
            _chips<int>('الإطارات في الثانية (FPS)', 'fps', 30,
                [10, 15, 24, 30, 60], ['10', '15', '24', '30', '60']),
            _chips<int>('أقصى معدل بيانات', 'bitrate', 0,
                [0, 500, 1000, 2500, 5000],
                ['تلقائي', '0.5 Mbps', '1 Mbps', '2.5 Mbps', '5 Mbps']),
            _chips<String>('الكاميرا', 'facing', 'environment',
                ['environment', 'user'], ['الخلفية', 'الأمامية']),
            _chips<bool>(
                'صوت الكاميرا', 'mic', true, [true, false], ['مفعّل', 'مكتوم']),
          ]),
          _group('المشاهدة', Icons.visibility_rounded, [
            _chips<String>('عرض الفيديو', 'fit', 'contain',
                ['contain', 'cover'], ['كامل بدون قص', 'ملء الشاشة (قص)']),
            _chips<bool>('الدخول للشاشة العريضة تلقائياً', 'autoWide', true,
                [true, false], ['نعم', 'لا']),
          ]),
          _group('المدى والشبكة', Icons.wifi_tethering_rounded, [
            _chips<bool>('وضع المدى البعيد (جودة أقل = ثبات أكثر)', 'range', false,
                [false, true], ['إيقاف', 'تشغيل']),
            _chips<bool>('الاتصال من خارج الشبكة المحلية (STUN)', 'wan', false,
                [false, true], ['إيقاف', 'تشغيل']),
            _chips<bool>('ختم التاريخ والوقت على العرض', 'clock', true,
                [true, false], ['نعم', 'لا']),
            Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kBg,
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Text(
                'لزيادة المسافة:\n'
                '• استخدم واي فاي 2.4GHz (أبعد من 5GHz).\n'
                '• قرّب الراوتر أو أضف مقوّي إشارة (Mesh/Repeater).\n'
                '• إن كانت الإشارة ضعيفة فعّل "المدى البعيد" أو اترك الجودة التلقائية تعمل.\n'
                '• للمشاهدة من خارج البيت: ثبّت Tailscale (مجاني) على الهاتفين واكتب عنوان 100.x الظاهر في الكاميرا. لا تفتح المنافذ 8080/8081 في الراوتر.',
                style: TextStyle(fontSize: 12, color: Colors.white70, height: 1.6),
              ),
            ),
          ]),
          _group('مشاركة الشاشة والتحكم', Icons.phone_android_rounded, [
            _chips<int>('الإطارات', 'sfps', 10, [5, 10, 15], ['5', '10', '15']),
            _chips<int>('جودة الصورة', 'squality', 60, [40, 60, 80],
                ['منخفضة', 'متوسطة', 'عالية']),
            _chips<int>('الدقة', 'sside', 1280, [960, 1280, 1920],
                ['منخفضة', 'متوسطة', 'عالية']),
          ]),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 22),
            child: Text('إعدادات البث والصوت تُطبّق عند فتح وضع الكاميرا من جديد.',
                style: TextStyle(fontSize: 12, color: Colors.white54)),
          ),
        ]),
      );
}

// ───────────────────────── Camera (broadcaster) ─────────────────────────
class CameraPage extends StatefulWidget {
  const CameraPage({super.key, this.autoMinimize = false});
  final bool autoMinimize;
  static bool active = false;
  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> with WidgetsBindingObserver {
  final _local = RTCVideoRenderer();
  MediaStream? _stream;
  HttpServer? _server;
  RTCPeerConnection? _pc;
  WebSocket? _ws;
  MediaRecorder? _rec;
  String _ip = '...';
  String _pin = '------';
  String _status = 'بانتظار المشاهد';
  bool _recording = false;
  bool _always = false;
  Map _diag = {};
  Map _screen = {};
  Timer? _diagTimer;
  WebSocket? _screenWs;
  StreamSubscription? _screenSub;
  int _screenW = 0;
  int _screenH = 0;
  int _kbps = 0;
  int _fps = 30;
  // health / adaptive quality / pairing
  final _battery = Battery();
  Timer? _healthTimer;
  Timer? _adaptTimer;
  Timer? _clockTimer;
  Map<String, dynamic> _myHealth = {};
  final _now = ValueNotifier<DateTime>(DateTime.now());
  static const List<List<num>> _levels = [
    [0, 1.0],
    [1500, 1.0],
    [800, 1.5],
    [400, 2.0],
    [200, 3.0],
  ];
  int _level = 0;
  int _good = 0;
  bool _throttled = false;
  bool _range = false;
  bool _clockOn = true;
  List<MapEntry<String, String>> _ips = [];
  final Map<String, List<DateTime>> _fails = {};
  IOSink? _srt;
  Timer? _srtTimer;
  int _srtN = 0;
  DateTime? _recStart;

  @override
  void initState() {
    super.initState();
    CameraPage.active = true;
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable(); // keep the screen on while broadcasting
    _start();
  }

  Future<void> _start() async {
    final s = await loadSettings();
    _pin = (s['campin'] as String?) ?? _newPin();
    await saveSettings({'campin': _pin});
    _always = (s['always'] as bool?) ?? false;
    _range = (s['range'] as bool?) ?? false;
    _clockOn = (s['clock'] as bool?) ?? true;
    _level = _range ? 3 : 0;
    await applyNetConfig();
    if (Platform.isAndroid) {
      try {
        await _svc.invokeMethod('config', {'always': _always, 'pin': _pin});
      } catch (_) {}
    }

    await _landscape(); // wide capture
    await Future.delayed(const Duration(milliseconds: 600));
    await [Permission.camera, Permission.microphone].request();
    await _local.initialize();
    final hRes = (s['res'] as int?) ?? 720;
    final wRes = (hRes * 16 / 9).round();
    final fps = (s['fps'] as int?) ?? 30;
    final facing = (s['facing'] as String?) ?? 'environment';
    final mic = (s['mic'] as bool?) ?? true;
    _kbps = (s['bitrate'] as int?) ?? 0;
    _fps = fps;
    try {
      _stream = await navigator.mediaDevices.getUserMedia({
        'audio': mic,
        'video': {
          'mandatory': {
            'minWidth': '$wRes',
            'minHeight': '$hRes',
            'minFrameRate': '$fps'
          },
          'facingMode': facing,
          'optional': [],
        },
      });
    } catch (_) {
      try {
        _stream = await navigator.mediaDevices.getUserMedia({
          'audio': mic,
          'video': {
            'mandatory': {'minWidth': '$wRes', 'minHeight': '$hRes'},
            'facingMode': facing,
            'optional': [],
          },
        });
      } catch (_) {
        _stream = await navigator.mediaDevices.getUserMedia({
          'audio': mic,
          'video': {'facingMode': facing},
        });
      }
    }
    _local.srcObject = _stream;
    _ip = await localIp() ?? '...';
    _ips = await allIps();

    // Android: run as a foreground service so it keeps working in the
    // background / with the screen off / after the app is swiped away.
    if (Platform.isAndroid) {
      await Permission.notification.request();
      try {
        await _svc.invokeMethod('start');
      } catch (_) {}
    }

    _server = await HttpServer.bind(InternetAddress.anyIPv4, kPort);
    _server!.listen((req) async {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        req.response
          ..write('LAN Cam')
          ..close();
        return;
      }
      final remote = req.connectionInfo?.remoteAddress.address ?? '?';
      final ws = await WebSocketTransformer.upgrade(req);
      var authed = false;
      ws.listen((m) async {
        if (m is! String) return;
        final d = jsonDecode(m);
        switch (d['type']) {
          case 'offer':
            if (_locked(remote)) {
              ws.add(jsonEncode({'type': 'locked'}));
              await ws.close();
              return;
            }
            if ((d['pin'] ?? '') != _pin) {
              _fails.putIfAbsent(remote, () => []).add(DateTime.now());
              ws.add(jsonEncode({'type': 'denied'}));
              await ws.close();
              return;
            }
            _fails.remove(remote);
            authed = true;
            _ws = ws;
            await _answer(ws, d['sdp'] as String);
            _sendRec();
            break;
          case 'record':
            if (authed) await _setRec(d['on'] == true);
            break;
          case 'cmd':
            if (authed) await _cmd(d);
            break;
          case 'screen':
            if (_locked(remote)) {
              ws.add(jsonEncode({'type': 'locked'}));
              await ws.close();
              return;
            }
            if ((d['pin'] ?? '') != _pin) {
              _fails.putIfAbsent(remote, () => []).add(DateTime.now());
              ws.add(jsonEncode({'type': 'denied'}));
              await ws.close();
              return;
            }
            _fails.remove(remote);
            authed = true;
            await _attachScreen(ws);
            break;
          case 'tap':
          case 'swipe':
          case 'nav':
            if (authed) await _remoteInput(d);
            break;
        }
      }, onDone: () => _detachScreen(ws));
    });
    if (mounted) setState(() {});
    _refreshDiag();
    _diagTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => _refreshDiag());
    _healthTimer =
        Timer.periodic(const Duration(seconds: 4), (_) => _sendHealth());
    _adaptTimer = Timer.periodic(const Duration(seconds: 3), (_) => _adapt());
    _clockTimer = Timer.periodic(
        const Duration(seconds: 1), (_) => _now.value = DateTime.now());
    _sendHealth();

    // Woken remotely while the app was closed: hide again once we are live.
    if (widget.autoMinimize && Platform.isAndroid) {
      await Future.delayed(const Duration(seconds: 3));
      try {
        await _svc.invokeMethod('toBack');
      } catch (_) {}
    }
  }

  Future<void> _answer(WebSocket ws, String sdp) async {
    await _pc?.close();
    final pc = _pc = await createPeerConnection(kPcConfig);
    for (final t in _stream!.getTracks()) {
      await pc.addTrack(t, _stream!);
    }
    pc.onConnectionState = (s) {
      if (mounted) {
        setState(() => _status = s.name.replaceAll('RTCPeerConnectionState', ''));
      }
      if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        _applyEncoding(pc);
      }
    };
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    final ans = await pc.createAnswer();
    await pc.setLocalDescription(ans);
    await waitIceGathered(pc);
    final l = await pc.getLocalDescription();
    ws.add(jsonEncode({'type': 'answer', 'sdp': l!.sdp}));
  }

  /// Apply bitrate / fps / resolution scale (user settings + adaptive level).
  Future<void> _applyEncoding(RTCPeerConnection pc) async {
    final lv = _levels[_level];
    final lk = lv[0].toInt();
    var cap = _kbps;
    if (lk > 0) cap = cap > 0 ? min(cap, lk) : lk;
    final scale = lv[1].toDouble();
    final fps = _level >= 3 ? min(_fps, 15) : _fps;
    if (cap <= 0 && scale == 1.0 && !_throttled) return;
    try {
      final senders = await pc.getSenders();
      for (final snd in senders) {
        if (snd.track?.kind != 'video') continue;
        final p = (snd as dynamic).parameters;
        final encs = p.encodings as List?;
        if (encs == null || encs.isEmpty) continue;
        for (final e in encs) {
          try {
            (e as dynamic).maxBitrate = cap > 0 ? cap * 1000 : null;
          } catch (_) {}
          try {
            (e as dynamic).maxFramerate = fps;
          } catch (_) {}
          try {
            (e as dynamic).scaleResolutionDownBy = scale;
          } catch (_) {}
        }
        await (snd as dynamic).setParameters(p);
      }
      _throttled = _level > 0;
    } catch (_) {}
  }

  bool _locked(String ip) {
    final l = _fails[ip];
    if (l == null) return false;
    l.removeWhere(
        (t) => DateTime.now().difference(t) > const Duration(minutes: 5));
    return l.length >= 5;
  }

  /// Weak link -> lower quality automatically; good link -> step back up.
  Future<void> _adapt() async {
    final pc = _pc;
    if (pc == null || _ws == null) return;
    if (pc.connectionState !=
        RTCPeerConnectionState.RTCPeerConnectionStateConnected) return;
    var loss = 0.0;
    var rtt = 0.0;
    try {
      for (final r in await pc.getStats()) {
        final v = r.values;
        if (r.type == 'remote-inbound-rtp') {
          if ('${v['kind'] ?? v['mediaType']}' == 'audio') continue;
          loss = max(loss, numOf(v['fractionLost']));
          rtt = max(rtt, numOf(v['roundTripTime']));
        } else if (r.type == 'candidate-pair' && '${v['nominated']}' == 'true') {
          rtt = max(rtt, numOf(v['currentRoundTripTime']));
        }
      }
    } catch (_) {
      return;
    }
    final floor = _range ? 3 : 0;
    final before = _level;
    if (loss > 0.06 || rtt > 0.45) {
      _good = 0;
      if (_level < 4) _level++;
    } else if (loss < 0.02 && rtt < 0.2) {
      _good++;
      if (_good >= 4 && _level > floor) {
        _level--;
        _good = 0;
      }
    } else {
      _good = 0;
    }
    if (_level < floor) _level = floor;
    if (_level != before) await _applyEncoding(pc);
  }

  /// Battery / temperature / Wi-Fi strength -> viewer (every 4 s).
  Future<void> _sendHealth() async {
    final m = <String, dynamic>{
      'ts': DateTime.now().millisecondsSinceEpoch,
      'q': _level,
      'range': _range,
    };
    try {
      m['bat'] = await _battery.batteryLevel;
      final st = await _battery.batteryState;
      m['chg'] = st == BatteryState.charging || st == BatteryState.full;
    } catch (_) {}
    if (Platform.isAndroid) {
      try {
        final h = await _svc.invokeMethod<Map>('health');
        if (h != null) {
          if (h['temp'] != null) m['temp'] = h['temp'];
          if (h['rssi'] != null) m['rssi'] = h['rssi'];
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() => _myHealth = m);
    try {
      _ws?.add(jsonEncode({'type': 'health', ...m}));
    } catch (_) {}
  }

  void _showQr() {
    final cands = _ips.isEmpty ? [MapEntry('wifi', _ip)] : _ips;
    var sel = cands.indexWhere((e) => e.value == _ip);
    if (sel < 0) sel = 0;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setM) => AlertDialog(
          backgroundColor: kSurface,
          title: const Text('ربط سريع عبر QR'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
              ),
              child: QrImageView(
                data: 'LANCAM|${cands[sel].value}|$kPort|$_pin',
                version: QrVersions.auto,
                size: 210,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 10),
            Text('${cands[sel].value}  (${cands[sel].key})',
                textDirection: TextDirection.ltr,
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
            if (cands.length > 1)
              Wrap(spacing: 6, children: [
                for (var i = 0; i < cands.length; i++)
                  ChoiceChip(
                    label: Text(cands[i].value,
                        style: const TextStyle(fontSize: 11)),
                    selected: i == sel,
                    onSelected: (_) => setM(() => sel = i),
                  ),
              ]),
            const SizedBox(height: 8),
            const Text('الرمز يحتوي على الـ PIN — لا تعرضه لأحد لا تثق به.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.amber)),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
          ],
        ),
      ),
    );
  }

  void _startSrt(String path, DateTime t0) {
    try {
      _recStart = t0;
      _srtN = 0;
      _srt = File(path).openWrite(encoding: utf8);
      _srtTimer =
          Timer.periodic(const Duration(seconds: 1), (_) => _srtTick());
      _srtTick();
    } catch (_) {}
  }

  void _srtTick() {
    final w = _srt;
    final t0 = _recStart;
    if (w == null || t0 == null) return;
    final now = DateTime.now();
    final ms = now.difference(t0).inMilliseconds;
    _srtN++;
    w.write('$_srtN\n${srtTime(ms)} --> ${srtTime(ms + 1000)}\n${fmtStamp(now)}\n\n');
  }

  Future<void> _stopSrt() async {
    _srtTimer?.cancel();
    _srtTimer = null;
    try {
      await _srt?.flush();
      await _srt?.close();
    } catch (_) {}
    _srt = null;
  }

  // ── phone screen sharing + remote control (Android host) ──
  Future<void> _attachScreen(WebSocket ws) async {
    Map info = {};
    try {
      info = (await _svc.invokeMethod<Map>('screenInfo')) ?? {};
    } catch (_) {}
    if (info['running'] != true) {
      ws.add(jsonEncode({
        'type': 'screen_error',
        'msg':
            'مشاركة الشاشة غير مفعّلة على الجهاز الآخر — افتح التطبيق هناك واضغط "بدء مشاركة الشاشة"'
      }));
      return;
    }
    _screenW = (info['w'] as int?) ?? 0;
    _screenH = (info['h'] as int?) ?? 0;
    _screenSub?.cancel();
    _screenWs = ws;
    ws.add(jsonEncode({
      'type': 'screen_info',
      'w': _screenW,
      'h': _screenH,
      'control': info['control'] == true,
    }));
    try {
      await _svc.invokeMethod('screenWanted', {'on': true});
    } catch (_) {}
    _screenSub = _screenEvents.receiveBroadcastStream().listen((data) {
      if (data is Uint8List) {
        try {
          ws.add(data);
        } catch (_) {}
      }
    });
  }

  void _detachScreen(WebSocket ws) {
    if (!identical(_screenWs, ws)) return;
    _screenSub?.cancel();
    _screenSub = null;
    _screenWs = null;
    if (Platform.isAndroid) {
      _svc.invokeMethod('screenWanted', {'on': false}).catchError((_) {});
    }
  }

  Future<void> _remoteInput(Map d) async {
    if (_screenW == 0 || _screenH == 0) return;
    try {
      switch (d['type']) {
        case 'tap':
          await _svc.invokeMethod('tap', {
            'x': ((d['x'] as num) * _screenW).toDouble(),
            'y': ((d['y'] as num) * _screenH).toDouble(),
          });
          break;
        case 'swipe':
          await _svc.invokeMethod('swipe', {
            'x1': ((d['x1'] as num) * _screenW).toDouble(),
            'y1': ((d['y1'] as num) * _screenH).toDouble(),
            'x2': ((d['x2'] as num) * _screenW).toDouble(),
            'y2': ((d['y2'] as num) * _screenH).toDouble(),
            'ms': (d['ms'] as num).toInt(),
          });
          break;
        case 'nav':
          await _svc.invokeMethod('nav', {'action': d['action']});
          break;
      }
    } catch (_) {}
  }

  Future<void> _startScreen() async {
    final cfg = await loadSettings();
    try {
      await _svc.invokeMethod('screenConfig', {
        'fps': (cfg['sfps'] as int?) ?? 10,
        'quality': (cfg['squality'] as int?) ?? 60,
        'maxSide': (cfg['sside'] as int?) ?? 1280,
      });
      await _svc.invokeMethod('screenStart');
    } catch (_) {}
    Future.delayed(const Duration(seconds: 2), _refreshDiag);
  }

  Future<void> _stopScreen() async {
    try {
      await _svc.invokeMethod('screenStop');
    } catch (_) {}
    _refreshDiag();
  }

  Widget _screenBox() {
    final running = _screen['running'] == true;
    final control = _screen['control'] == true;
    final err = (_screen['error'] as String?) ?? '';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('مشاركة الشاشة والتحكم',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        _diagRow('الشاشة جاهزة للمشاهدة', running),
        _diagRow('التحكم عن بعد مفعّل', control),
        if (err.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(err,
                style: const TextStyle(fontSize: 10, color: Colors.amber)),
          ),
        const SizedBox(height: 6),
        OutlinedButton(
          onPressed: running ? _stopScreen : _startScreen,
          child: Text(running ? 'إيقاف مشاركة الشاشة' : 'بدء مشاركة الشاشة'),
        ),
        if (!control)
          TextButton(
            onPressed: () => _svc.invokeMethod('openAccessibility'),
            child: const Text('تفعيل التحكم (إمكانية الوصول)'),
          ),
      ]),
    );
  }

  /// Remote controls from the viewer: switch camera / flashlight.
  Future<void> _cmd(Map<String, dynamic> d) async {
    if (d['cmd'] == 'range') {
      _range = d['on'] == true;
      saveSettings({'range': _range});
      if (_range && _level < 3) _level = 3;
      final pc = _pc;
      if (pc != null) await _applyEncoding(pc);
      if (mounted) setState(() {});
      return;
    }
    final tracks = _stream?.getVideoTracks();
    if (tracks == null || tracks.isEmpty) return;
    final v = tracks.first;
    try {
      if (d['cmd'] == 'switch') {
        await Helper.switchCamera(v);
      } else if (d['cmd'] == 'torch') {
        await (v as dynamic).setTorch(d['on'] == true);
      }
    } catch (_) {}
  }

  void _sendRec({bool ok = true}) {
    try {
      _ws?.add(jsonEncode({'type': 'rec', 'on': _recording, 'ok': ok}));
    } catch (_) {}
  }

  Future<void> _setRec(bool on) async {
    if (!Platform.isAndroid) {
      _sendRec(ok: false);
      return;
    }
    if (on != _recording) await _toggleRec();
    _sendRec();
  }

  Future<void> _toggleRec() async {
    if (!Platform.isAndroid) return; // flutter_webrtc recorder: Android only
    if (_recording) {
      await _rec?.stop();
      await _stopSrt();
      if (mounted) setState(() => _recording = false);
      return;
    }
    final dir = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final t0 = DateTime.now();
    final path = '${dir.path}/cam_${fmtFile(t0)}.mp4';
    _rec = MediaRecorder();
    await _rec!.start(path,
        videoTrack: _stream!.getVideoTracks().first,
        audioChannel: RecorderAudioChannel.INPUT);
    // subtitle file with the date/time (players show it next to the video)
    _startSrt(path.replaceFirst(RegExp(r'\.mp4$'), '.srt'), t0);
    if (mounted) setState(() => _recording = true);
  }

  @override
  void dispose() {
    CameraPage.active = false;
    _diagTimer?.cancel();
    _healthTimer?.cancel();
    _adaptTimer?.cancel();
    _clockTimer?.cancel();
    _now.dispose();
    _stopSrt();
    _screenSub?.cancel();
    if (Platform.isAndroid) {
      _svc.invokeMethod('screenStop').catchError((_) {});
    }
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    if (Platform.isAndroid) {
      // always-ready: keep the standby listener, otherwise stop everything
      _svc.invokeMethod(_always ? 'standby' : 'stop').catchError((_) {});
    }
    _rec?.stop();
    _ws?.close();
    _pc?.close();
    _server?.close(force: true);
    _stream?.dispose();
    _local.dispose();
    _portrait();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // a new Activity may have been created (engine survives): re-apply wide mode
    if (state == AppLifecycleState.resumed) _landscape();
  }

  Future<void> _toggleAlways(bool v) async {
    if (!Platform.isAndroid) return;
    if (v) {
      var overlay = true;
      try {
        overlay = (await _svc.invokeMethod<bool>('hasOverlay')) ?? true;
      } catch (_) {}
      if (!overlay) {
        try {
          await _svc.invokeMethod('overlay');
        } catch (_) {}
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('فعّل "الظهور فوق التطبيقات" لـ LAN Cam ثم ارجع'),
              duration: Duration(seconds: 6)));
        }
      }
    }
    setState(() => _always = v);
    saveSettings({'always': v});
    try {
      await _svc.invokeMethod('config', {'always': v, 'pin': _pin});
      await _svc.invokeMethod('start'); // re-apply (starts/stops the listener)
    } catch (_) {}
    _refreshDiag();
  }

  Future<void> _refreshDiag() async {
    if (!Platform.isAndroid) return;
    try {
      final m = await _svc.invokeMethod<Map>('status');
      final sc = await _svc.invokeMethod<Map>('screenInfo');
      if (mounted) {
        setState(() {
          if (m != null) _diag = m;
          if (sc != null) _screen = sc;
        });
      }
    } catch (_) {}
  }

  Widget _diagRow(String label, bool ok) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Icon(ok ? Icons.check_circle : Icons.cancel,
              size: 14, color: ok ? kGreen : kRed),
          const SizedBox(width: 6),
          Expanded(
            child: Text(label,
                style: const TextStyle(fontSize: 11, color: Colors.white70)),
          ),
        ]),
      );

  Widget _diagBox() {
    final err = (_diag['error'] as String?) ?? '';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: kBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _diagRow('الخدمة في الخلفية', _diag['running'] == true),
        _diagRow('منفذ الإيقاظ $kWakePort', _diag['listening'] == true),
        _diagRow('الظهور فوق التطبيقات', _diag['overlay'] == true),
        _diagRow('توفير البطارية مستثنى', _diag['battery'] == true),
        if (err.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: SelectableText(err,
                style: const TextStyle(fontSize: 10, color: Colors.amber)),
          ),
      ]),
    );
  }

  bool get _live => _status == 'Connected';

  Widget _panel() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white10),
        ),
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: const [
              LogoMark(size: 30),
              SizedBox(width: 8),
              Text('LAN Cam',
                  style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      letterSpacing: 1)),
            ]),
            const SizedBox(height: 12),
            InfoRow(label: 'العنوان', value: '$_ip:$kPort'),
            const SizedBox(height: 8),
            InfoRow(
              label: 'رمز الدخول (PIN)',
              value: _pin,
              big: true,
              trailing: IconButton(
                icon: const Icon(Icons.refresh_rounded, size: 20),
                color: Colors.white54,
                onPressed: () {
                  setState(() => _pin = _newPin());
                  saveSettings({'campin': _pin});
                  if (Platform.isAndroid) {
                    _svc
                        .invokeMethod('config', {'always': _always, 'pin': _pin})
                        .catchError((_) {});
                  }
                },
              ),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: _live ? kGreen : Colors.amber,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(_live ? 'متصل — يوجد مشاهد' : _status,
                    style: const TextStyle(fontSize: 13, color: Colors.white70)),
              ),
            ]),
            const SizedBox(height: 10),
            if (_myHealth.isNotEmpty) HealthBar(h: _myHealth),
            if (_myHealth.isNotEmpty) const SizedBox(height: 10),
            for (final e in _ips.where((e) => e.value != _ip))
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('${e.key}: ${e.value}  (شبكة أخرى / VPN)',
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(fontSize: 11, color: Colors.white54)),
              ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(40),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              icon: const Icon(Icons.qr_code_2_rounded, size: 20),
              label: const Text('عرض رمز QR للربط'),
              onPressed: _showQr,
            ),
            const SizedBox(height: 10),
            if (Platform.isAndroid)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: kBg,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('جاهزية دائمة',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  subtitle: const Text('اتصل في أي وقت حتى لو التطبيق مغلق',
                      style: TextStyle(fontSize: 11, color: Colors.white54)),
                  value: _always,
                  onChanged: _toggleAlways,
                ),
              ),
            if (Platform.isAndroid && _always) _diagBox(),
            if (Platform.isAndroid) _screenBox(),
            if (Platform.isAndroid)
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: _recording ? kRed : null,
                  minimumSize: const Size.fromHeight(46),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon: Icon(_recording ? Icons.stop_rounded : Icons.fiber_manual_record),
                label: Text(_recording ? 'إيقاف التسجيل' : 'تسجيل'),
                onPressed: () async {
                  await _toggleRec();
                  _sendRec();
                },
              )
            else
              const Text('التسجيل متاح على Android فقط',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
            if (Platform.isAndroid)
              TextButton.icon(
                icon: const Icon(Icons.battery_saver, size: 18),
                label: const Text('السماح بالعمل بالخلفية'),
                onPressed: () => _svc.invokeMethod('battery'),
              ),
          ]),
        ),
      );

  Widget _preview() => ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Stack(fit: StackFit.expand, children: [
          Container(color: Colors.black),
          RTCVideoView(_local),
          if (_clockOn)
            Positioned(left: 10, bottom: 10, child: ClockStamp(time: _now)),
          Positioned(
            top: 10,
            right: 10,
            child: Row(children: [
              Pill(
                  color: _live ? kRed : Colors.grey,
                  text: _live ? 'LIVE' : 'STANDBY'),
              if (_recording) ...[
                const SizedBox(width: 8),
                const Pill(color: kRed, text: 'REC'),
              ],
              const SizedBox(width: 8),
              RoundIcon(
                icon: Icons.arrow_back_rounded,
                onTap: () => Navigator.maybePop(context),
              ),
            ]),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: OrientationBuilder(builder: (context, o) {
              if (o == Orientation.landscape) {
                return Row(children: [
                  Expanded(child: _preview()),
                  const SizedBox(width: 10),
                  SizedBox(width: 264, child: _panel()),
                ]);
              }
              return Column(children: [
                Expanded(child: _preview()),
                const SizedBox(height: 10),
                SizedBox(height: 330, child: _panel()),
              ]);
            }),
          ),
        ),
      );
}

// ───────────────────────────── Viewer ─────────────────────────────
class ViewerPage extends StatefulWidget {
  const ViewerPage({
    super.key,
    this.screen = false,
    this.initialIp,
    this.initialPin,
    this.autoConnect = false,
  });
  final bool screen; // true = view + control another phone's screen
  final String? initialIp;
  final String? initialPin;
  final bool autoConnect;
  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> with WidgetsBindingObserver {
  final _remote = RTCVideoRenderer();
  final _ipCtl = TextEditingController();
  final _pinCtl = TextEditingController();
  RTCPeerConnection? _pc;
  WebSocket? _ws;
  MediaStream? _mic;
  MediaStreamTrack? _micTrack;
  String _status = '';
  List<String> _found = [];
  bool _scanning = false;
  bool _pinActive = false;
  bool _isConnected = false;
  bool _wide = false;
  bool _autoWideDone = false;
  bool _denied = false;
  bool _talking = false;
  bool _muted = false;
  bool _torch = false;
  bool _remoteRec = false;
  bool _fitCover = false;
  bool _autoWide = true;
  // phone-screen mode
  Uint8List? _frame;
  int _sw = 0;
  int _sh = 0;
  bool _ctl = false;
  Offset? _panStart;
  Offset? _panLast;
  DateTime _panT = DateTime.now();
  // health / link / auto-reconnect / night view / zoom
  Map<String, dynamic> _health = {};
  String _link = '';
  Timer? _statsTimer;
  Timer? _retryTimer;
  Timer? _lostTimer;
  Timer? _clockTimer;
  final _now = ValueNotifier<DateTime>(DateTime.now());
  int _camOffsetMs = 0;
  bool _wantLive = false;
  bool _connecting = false;
  bool _wasLive = false;
  int _retryN = 0;
  int _night = 0;
  bool _clockOn = true;
  bool _range = false;
  int _prevLost = 0;
  int _prevRecv = 0;
  bool _alertedBat20 = false;
  bool _alertedBat10 = false;
  bool _alertedTemp = false;
  final _tc = TransformationController();

  RTCVideoViewObjectFit get _fit => _fitCover
      ? RTCVideoViewObjectFit.RTCVideoViewObjectFitCover
      : RTCVideoViewObjectFit.RTCVideoViewObjectFitContain;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _remote.initialize();
    _clockTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _now.value =
            DateTime.now().add(Duration(milliseconds: _camOffsetMs)));
    _statsTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => _pollStats());
    loadSettings().then((s) {
      if (!mounted) return;
      _ipCtl.text = widget.initialIp ?? (s['ip'] as String?) ?? '';
      _pinCtl.text = widget.initialPin ?? (s['pin'] as String?) ?? '';
      setState(() {
        _fitCover = (s['fit'] as String?) == 'cover';
        _autoWide = (s['autoWide'] as bool?) ?? true;
        _night = (s['night'] as int?) ?? 0;
        _clockOn = (s['clock'] as bool?) ?? true;
        _range = (s['range'] as bool?) ?? false;
      });
      if (widget.autoConnect && widget.initialIp != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _connect();
        });
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // coming back to the app: keep the wide screen
    if (state == AppLifecycleState.resumed && _wide) {
      _landscape(immersive: true);
    }
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
    }
  }

  // ── keypad ──
  void _key(String k) {
    final c = _pinActive ? _pinCtl : _ipCtl;
    if (_pinActive && k == '.') return;
    final t = c.text + k;
    c.value = TextEditingValue(
        text: t, selection: TextSelection.collapsed(offset: t.length));
  }

  void _back() {
    final c = _pinActive ? _pinCtl : _ipCtl;
    if (c.text.isEmpty) return;
    final t = c.text.substring(0, c.text.length - 1);
    c.value = TextEditingValue(
        text: t, selection: TextSelection.collapsed(offset: t.length));
  }

  // ── auto discovery ──
  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _found = [];
      _status = 'جاري البحث عن الكاميرات...';
    });
    final r = await scanLan();
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _found = r;
      _status = r.isEmpty ? 'ما لقيت كاميرا على الشبكة' : 'لقيت ${r.length}';
      if (r.length == 1) {
        _ipCtl.text = r.first;
        _pinActive = true; // next: type the PIN
      }
    });
  }

  Future<void> _setWide(bool w) async {
    if (w) {
      await _landscape(immersive: true);
    } else {
      await _portrait();
    }
    if (mounted) setState(() => _wide = w);
  }

  void _scheduleRetry([String? why]) {
    if (!_wantLive || _denied || !mounted) return;
    if (_retryTimer?.isActive == true) return;
    _retryN++;
    final secs = min(10, 1 + _retryN * 2);
    setState(() {
      _isConnected = false;
      _status = '${why ?? 'انقطع الاتصال'} — إعادة المحاولة بعد $secs ث ($_retryN)';
    });
    _retryTimer = Timer(Duration(seconds: secs), () {
      if (mounted && _wantLive && !_denied) _connect(retry: true);
    });
  }

  void _stopRetry() {
    _wantLive = false;
    _retryTimer?.cancel();
    _lostTimer?.cancel();
    setState(() => _status = 'تم إيقاف المحاولة');
  }

  /// The link dropped after having been live: alert, then retry.
  void _onLost() {
    if (!_wantLive || _denied || !mounted) return;
    if (_wasLive) {
      _wasLive = false;
      _alert('انقطع الاتصال بالكاميرا — جاري إعادة الاتصال');
    }
    final p = _pc;
    final w = _ws;
    _pc = null;
    _ws = null;
    p?.close();
    w?.close();
    _scheduleRetry();
  }

  Future<void> _connect({bool retry = false}) async {
    if (_connecting || !mounted) return;
    if (!retry) FocusScope.of(context).unfocus();
    final ip = _ipCtl.text.trim();
    if (ip.isEmpty) {
      _snack('اكتب IP الكاميرا أو اضغط بحث');
      return;
    }
    _connecting = true;
    saveSettings({'ip': ip, 'pin': _pinCtl.text});
    _denied = false;
    _wantLive = true;
    _retryTimer?.cancel();
    try {
      await applyNetConfig();
      if (mounted) {
        setState(() => _status =
            retry ? 'إعادة الاتصال ($_retryN)...' : 'جاري الاتصال...');
      }
      if (!await _portOpen(ip, kPort)) {
        // camera app is closed: wake it (standby listener on the camera phone)
        if (mounted) setState(() => _status = 'الكاميرا مغلقة — جاري إيقاظها...');
        final woke = await _wakeCamera(ip, _pinCtl.text);
        if (woke != 'ok') throw 'wake-$woke';
        var up = false;
        for (var i = 0; i < 25 && !up && _wantLive; i++) {
          await Future.delayed(const Duration(seconds: 1));
          up = await _portOpen(ip, kPort);
        }
        if (!up) throw 'wake-timeout';
        if (mounted) setState(() => _status = 'جاري الاتصال...');
      }
      if (!mounted || !_wantLive) return;
      if (widget.screen) {
        await _connectScreen(ip);
        return;
      }
      final oldPc = _pc;
      final oldWs = _ws;
      _pc = null;
      _ws = null;
      await oldPc?.close();
      oldWs?.close();
      final ws = _ws = await WebSocket.connect('ws://$ip:$kPort')
          .timeout(const Duration(seconds: 5));

      // Microphone (talk-back to the camera). Starts muted.
      if (_micTrack == null) {
        try {
          _mic = await navigator.mediaDevices
              .getUserMedia({'audio': true, 'video': false});
          _micTrack = _mic!.getAudioTracks().first;
          _micTrack!.enabled = _talking;
        } catch (_) {
          _micTrack = null;
        }
      }

      final pc = _pc = await createPeerConnection(kPcConfig);
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      if (_micTrack != null) {
        await pc.addTransceiver(
          track: _micTrack!,
          init: RTCRtpTransceiverInit(
            direction: TransceiverDirection.SendRecv,
            streams: [_mic!],
          ),
        );
      } else {
        await pc.addTransceiver(
          kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
      }
      try {
        await Helper.setSpeakerphoneOn(true);
      } catch (_) {}

      pc.onTrack = (e) {
        if (e.streams.isNotEmpty && mounted) {
          setState(() => _remote.srcObject = e.streams.first);
          if (_muted) {
            for (final t in e.streams.first.getAudioTracks()) {
              t.enabled = false;
            }
          }
        }
      };
      pc.onConnectionState = (s) {
        if (!mounted || !identical(_pc, pc)) return;
        final live = s == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
        setState(() {
          _status = s.name.replaceAll('RTCPeerConnectionState', '');
          _isConnected = live;
        });
        if (live) {
          _retryN = 0;
          _wasLive = true;
          _lostTimer?.cancel();
          _prevLost = 0;
          _prevRecv = 0;
          if (_autoWide && !_autoWideDone) {
            _autoWideDone = true;
            _setWide(true); // go wide automatically once connected
          }
        } else if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
          _onLost();
        } else if (s ==
            RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          // may recover by itself: give it a few seconds
          _lostTimer?.cancel();
          _lostTimer = Timer(const Duration(seconds: 4), () {
            if (mounted && !_isConnected) _onLost();
          });
        }
      };
      ws.listen((m) async {
        final d = jsonDecode(m as String);
        switch (d['type']) {
          case 'answer':
            await pc.setRemoteDescription(
                RTCSessionDescription(d['sdp'] as String, 'answer'));
            break;
          case 'rec':
            if (mounted) setState(() => _remoteRec = d['on'] == true);
            if (d['ok'] == false) {
              _snack('التسجيل غير مدعوم على جهاز الكاميرا (Android فقط)');
            }
            break;
          case 'health':
            _onHealth(d as Map);
            break;
          case 'denied':
            _denied = true;
            _wantLive = false;
            if (mounted) setState(() => _status = 'PIN غير صحيح');
            _snack('PIN غير صحيح');
            await pc.close();
            _ws?.close();
            break;
          case 'locked':
            _denied = true;
            _wantLive = false;
            if (mounted) {
              setState(() => _status = 'محاولات خاطئة كثيرة — انتظر 5 دقائق');
            }
            await pc.close();
            _ws?.close();
            break;
        }
      }, onDone: () {
        if (identical(_ws, ws)) _onLost();
      });

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await waitIceGathered(pc);
      final l = await pc.getLocalDescription();
      ws.add(jsonEncode({'type': 'offer', 'sdp': l!.sdp, 'pin': _pinCtl.text}));
    } catch (e) {
      if (e == 'wake-denied') _wantLive = false;
      _scheduleRetry(_friendly(e));
      if (!_wantLive && mounted) setState(() => _status = _friendly(e));
    } finally {
      _connecting = false;
    }
  }

  void _alert(String m) {
    HapticFeedback.heavyImpact();
    SystemSound.play(SystemSoundType.alert);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(m),
      backgroundColor: kRed,
      duration: const Duration(seconds: 6),
    ));
  }

  void _onHealth(Map d) {
    final m = Map<String, dynamic>.from(d);
    final ts = m['ts'];
    if (ts is num) {
      _camOffsetMs = ts.toInt() - DateTime.now().millisecondsSinceEpoch;
    }
    final bat = m['bat'];
    final chg = m['chg'] == true;
    if (bat is num) {
      if (chg || bat > 25) {
        _alertedBat20 = false;
        _alertedBat10 = false;
      } else if (bat <= 10 && !_alertedBat10) {
        _alertedBat10 = true;
        _alertedBat20 = true;
        _alert('بطارية الكاميرا ${bat.toInt()}% — وصّلها بالشاحن');
      } else if (bat <= 20 && !_alertedBat20) {
        _alertedBat20 = true;
        _alert('بطارية الكاميرا منخفضة ${bat.toInt()}%');
      }
    }
    final t = m['temp'];
    if (t is num) {
      if (t >= 45 && !_alertedTemp) {
        _alertedTemp = true;
        _alert('حرارة جهاز الكاميرا مرتفعة ${t.toStringAsFixed(0)}°');
      } else if (t < 41) {
        _alertedTemp = false;
      }
    }
    if (m['range'] is bool) _range = m['range'] as bool;
    if (mounted) setState(() => _health = m);
  }

  /// Link quality as measured on this phone (RTT + packet loss).
  Future<void> _pollStats() async {
    final pc = _pc;
    if (pc == null || !_isConnected || widget.screen) return;
    var rtt = 0.0;
    var lost = 0;
    var recv = 0;
    try {
      for (final r in await pc.getStats()) {
        final v = r.values;
        if (r.type == 'inbound-rtp' &&
            '${v['kind'] ?? v['mediaType']}' == 'video') {
          lost = numOf(v['packetsLost']).toInt();
          recv = numOf(v['packetsReceived']).toInt();
        } else if (r.type == 'candidate-pair' && '${v['nominated']}' == 'true') {
          rtt = max(rtt, numOf(v['currentRoundTripTime']));
        }
      }
    } catch (_) {
      return;
    }
    final dl = lost - _prevLost;
    final dr = recv - _prevRecv;
    _prevLost = lost;
    _prevRecv = recv;
    var loss = 0.0;
    if (dl >= 0 && dr >= 0 && dl + dr > 20) loss = dl / (dl + dr);
    final q = (loss > 0.08 || rtt > 0.5)
        ? 'poor'
        : ((loss > 0.025 || rtt > 0.25) ? 'fair' : 'good');
    if (mounted && q != _link) setState(() => _link = q);
  }

  Future<void> _scanQr() async {
    final v = await Navigator.push<String>(
        context, MaterialPageRoute(builder: (_) => const QrScanPage()));
    if (v == null || !mounted) return;
    final p = v.split('|');
    if (p.length < 4 || p[0] != 'LANCAM') {
      _snack('رمز غير صالح');
      return;
    }
    setState(() {
      _ipCtl.text = p[1];
      _pinCtl.text = p[3];
    });
    _connect();
  }

  Future<void> _shot() async {
    final tracks = _remote.srcObject?.getVideoTracks();
    if (tracks == null || tracks.isEmpty) {
      _snack('لا يوجد بث');
      return;
    }
    try {
      final buf = await tracks.first.captureFrame();
      final bytes = buf.asUint8List();
      try {
        if (!await Gal.hasAccess()) await Gal.requestAccess();
        await Gal.putImageBytes(bytes);
        _snack('تم حفظ اللقطة في الصور');
      } catch (_) {
        final dir = await getApplicationDocumentsDirectory();
        final f = File('${dir.path}/shot_${fmtFile(DateTime.now())}.png');
        await f.writeAsBytes(bytes);
        _snack('تم حفظ اللقطة: ${f.path}');
      }
    } catch (_) {
      _snack('تعذّر التقاط الصورة');
    }
  }

  void _tools() {
    showModalBottomSheet(
      context: context,
      backgroundColor: kSurface,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setM) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('رؤية ليلية (تحسين العرض)',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  Wrap(spacing: 8, children: [
                    for (var i = 0; i < 3; i++)
                      ChoiceChip(
                        label: Text(const ['إيقاف', 'ليلي', 'ليلي قوي'][i]),
                        selected: _night == i,
                        onSelected: (_) {
                          setState(() => _night = i);
                          setM(() {});
                          saveSettings({'night': i});
                        },
                      ),
                  ]),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('ختم التاريخ والوقت'),
                    value: _clockOn,
                    onChanged: (v) {
                      setState(() => _clockOn = v);
                      setM(() {});
                      saveSettings({'clock': v});
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('وضع المدى البعيد'),
                    subtitle: const Text(
                        'يخفّض الجودة ليبقى الاتصال ثابتاً مع الإشارة الضعيفة',
                        style: TextStyle(fontSize: 11, color: Colors.white54)),
                    value: _range,
                    onChanged: (v) {
                      setState(() => _range = v);
                      setM(() {});
                      _send({'type': 'cmd', 'cmd': 'range', 'on': v});
                    },
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.zoom_out_map_rounded),
                    label: const Text('إعادة ضبط الزوم'),
                    onPressed: () {
                      _tc.value = Matrix4.identity();
                      Navigator.pop(ctx);
                    },
                  ),
                ]),
          ),
        ),
      ),
    );
  }

  ColorFilter _nightFilter() {
    final g = _night == 1 ? 1.7 : 2.6;
    final o = _night == 1 ? 14.0 : 30.0;
    return ColorFilter.matrix(<double>[
      g, 0, 0, 0, o, //
      0, g, 0, 0, o, //
      0, 0, g, 0, o, //
      0, 0, 0, 1, 0,
    ]);
  }

  /// Live video: pinch to zoom (double-tap resets) + optional night view.
  Widget _videoView() {
    Widget v = RTCVideoView(_remote, objectFit: _fit);
    if (_night > 0) v = ColorFiltered(colorFilter: _nightFilter(), child: v);
    return GestureDetector(
      onDoubleTap: () => _tc.value = Matrix4.identity(),
      child: InteractiveViewer(
        transformationController: _tc,
        minScale: 1,
        maxScale: 6,
        child: v,
      ),
    );
  }

  Widget _hud() => IgnorePointer(
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          if (_clockOn && !widget.screen) ClockStamp(time: _now),
          if (_clockOn && !widget.screen) const SizedBox(height: 5),
          if (_isConnected && !widget.screen)
            HealthBar(h: _health, link: _link),
        ]),
      );

  Future<void> _connectScreen(String ip) async {
    final oldWs = _ws;
    _ws = null; // so the old socket's onDone is ignored
    oldWs?.close();
    _frame = null;
    final ws = _ws = await WebSocket.connect('ws://$ip:$kPort')
        .timeout(const Duration(seconds: 5));
    ws.listen((m) {
      if (!mounted) return;
      if (m is String) {
        final d = jsonDecode(m);
        switch (d['type']) {
          case 'screen_info':
            setState(() {
              _sw = (d['w'] as num).toInt();
              _sh = (d['h'] as num).toInt();
              _ctl = d['control'] == true;
              _isConnected = true;
              _retryN = 0;
              _status = _ctl
                  ? 'متصل — التحكم مفعّل'
                  : 'متصل — عرض فقط (فعّل التحكم على الجهاز الآخر)';
            });
            if (_autoWide && !_autoWideDone) {
              _autoWideDone = true;
              _setWide(true);
            }
            break;
          case 'screen_error':
            setState(() => _status = d['msg'] as String);
            break;
          case 'denied':
            _denied = true;
            _wantLive = false;
            setState(() => _status = 'PIN غير صحيح');
            _snack('PIN غير صحيح');
            ws.close();
            break;
          case 'locked':
            _denied = true;
            _wantLive = false;
            setState(() => _status = 'محاولات خاطئة كثيرة — انتظر 5 دقائق');
            ws.close();
            break;
        }
      } else if (m is List<int>) {
        setState(() => _frame = m is Uint8List ? m : Uint8List.fromList(m));
      }
    }, onDone: () {
      if (mounted && !_denied && identical(_ws, ws)) {
        if (_isConnected) _alert('انقطع الاتصال بشاشة الهاتف — جاري إعادة الاتصال');
        _isConnected = false;
        _ws = null;
        _scheduleRetry();
      }
    });
    ws.add(jsonEncode({'type': 'screen', 'pin': _pinCtl.text}));
  }

  Offset? _toNorm(Offset p, Size box) {
    if (_sw == 0 || _sh == 0) return null;
    final sc = min(box.width / _sw, box.height / _sh);
    final dw = _sw * sc;
    final dh = _sh * sc;
    final ox = (box.width - dw) / 2;
    final oy = (box.height - dh) / 2;
    final nx = (p.dx - ox) / dw;
    final ny = (p.dy - oy) / dh;
    if (nx < 0 || nx > 1 || ny < 0 || ny > 1) return null;
    return Offset(nx, ny);
  }

  /// The other phone's screen, with touch -> remote tap / swipe / long-press.
  Widget _screenArea() => LayoutBuilder(builder: (context, c) {
        final box = Size(c.maxWidth, c.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (d) {
            final n = _toNorm(d.localPosition, box);
            if (n != null) _send({'type': 'tap', 'x': n.dx, 'y': n.dy});
          },
          onLongPressStart: (d) {
            final n = _toNorm(d.localPosition, box);
            if (n != null) {
              _send({
                'type': 'swipe',
                'x1': n.dx,
                'y1': n.dy,
                'x2': n.dx,
                'y2': n.dy,
                'ms': 700
              });
            }
          },
          onPanStart: (d) {
            _panStart = d.localPosition;
            _panLast = d.localPosition;
            _panT = DateTime.now();
          },
          onPanUpdate: (d) => _panLast = d.localPosition,
          onPanEnd: (d) {
            final a = _panStart;
            final b = _panLast;
            if (a == null || b == null) return;
            final na = _toNorm(a, box);
            final nb = _toNorm(b, box);
            if (na == null || nb == null) return;
            final ms =
                DateTime.now().difference(_panT).inMilliseconds.clamp(80, 1200);
            _send({
              'type': 'swipe',
              'x1': na.dx,
              'y1': na.dy,
              'x2': nb.dx,
              'y2': nb.dy,
              'ms': ms.toInt(),
            });
          },
          child: Stack(fit: StackFit.expand, children: [
            Container(color: Colors.black),
            if (_frame != null)
              Image.memory(_frame!,
                  gaplessPlayback: true,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const SizedBox()),
            if (_frame == null)
              const Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.phone_android_rounded,
                      size: 40, color: Colors.white24),
                  SizedBox(height: 8),
                  Text('لا يوجد بث للشاشة',
                      style: TextStyle(color: Colors.white38)),
                ]),
              ),
          ]),
        );
      });

  Widget _screenControls({required bool dark}) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          CtlButton(
              icon: Icons.arrow_back,
              label: 'رجوع',
              dark: dark,
              onTap: () => _send({'type': 'nav', 'action': 'back'})),
          CtlButton(
              icon: Icons.home_rounded,
              label: 'الرئيسية',
              dark: dark,
              onTap: () => _send({'type': 'nav', 'action': 'home'})),
          CtlButton(
              icon: Icons.apps_rounded,
              label: 'التطبيقات',
              dark: dark,
              onTap: () => _send({'type': 'nav', 'action': 'recents'})),
          CtlButton(
              icon: Icons.notifications_rounded,
              label: 'الإشعارات',
              dark: dark,
              onTap: () => _send({'type': 'nav', 'action': 'notifications'})),
          CtlButton(
              icon: _wide ? Icons.fullscreen_exit : Icons.fullscreen,
              label: _wide ? 'تصغير' : 'عريض',
              dark: dark,
              onTap: () => _setWide(!_wide)),
        ],
      );

  Future<bool> _portOpen(String ip, int port) async {
    try {
      final s = await Socket.connect(ip, port,
          timeout: const Duration(milliseconds: 900));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 'ok' | 'unreachable' (port closed / wrong IP) | 'denied' (PIN / feature off) | 'noreply'
  Future<String> _wakeCamera(String ip, String pin) async {
    Socket s;
    try {
      s = await Socket.connect(ip, kWakePort,
          timeout: const Duration(seconds: 3));
    } catch (_) {
      return 'unreachable';
    }
    try {
      s.write('WAKE:$pin\n');
      await s.flush();
      final reply = await s
          .cast<List<int>>()
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 5), onTimeout: () => '');
      s.destroy();
      final r = reply.trim();
      if (r == 'OK') return 'ok';
      if (r == 'DENIED') return 'denied';
      return 'noreply';
    } catch (_) {
      return 'noreply';
    }
  }

  String _friendly(Object e) {
    if (e == 'wake-unreachable') {
      return 'الكاميرا لا تستقبل طلب الإيقاظ (المنفذ $kWakePort مغلق): الخدمة متوقفة على جهاز الكاميرا أو الـ IP غير صحيح';
    }
    if (e == 'wake-denied') {
      return 'الكاميرا رفضت الطلب: الـ PIN غير صحيح أو "جاهزية دائمة" غير مفعّلة';
    }
    if (e == 'wake-noreply') return 'الكاميرا ما ردّت على طلب الإيقاظ';
    if (e == 'wake-timeout') {
      return 'الكاميرا ما استجابت — افتح التطبيق على جهاز الكاميرا مرة واحدة';
    }
    if (e is SocketException) {
      return 'تعذّر الاتصال — تأكد أن الكاميرا شغالة وعلى نفس الشبكة';
    }
    if (e is TimeoutException) return 'انتهت مهلة الاتصال';
    return 'فشل الاتصال';
  }

  // ── controls ──
  void _toggleMic() {
    if (_micTrack == null) {
      _snack('الميكروفون غير متاح (تأكد من الصلاحية)');
      return;
    }
    setState(() {
      _talking = !_talking;
      _micTrack!.enabled = _talking;
    });
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    for (final t in _remote.srcObject?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !_muted;
    }
  }

  void _send(Map<String, dynamic> m) {
    if (_ws == null) {
      _snack('اتصل بالكاميرا أولاً');
      return;
    }
    _ws!.add(jsonEncode(m));
  }

  /// Recording happens on the camera phone (Android), commanded from here.
  void _toggleRec() => _send({'type': 'record', 'on': !_remoteRec});

  void _switchCam() => _send({'type': 'cmd', 'cmd': 'switch'});

  void _toggleTorch() {
    setState(() => _torch = !_torch);
    _send({'type': 'cmd', 'cmd': 'torch', 'on': _torch});
  }

  @override
  void dispose() {
    _wantLive = false;
    _retryTimer?.cancel();
    _lostTimer?.cancel();
    _statsTimer?.cancel();
    _clockTimer?.cancel();
    _now.dispose();
    _tc.dispose();
    WidgetsBinding.instance.removeObserver(this);
    WakelockPlus.disable();
    _pc?.close();
    _ws?.close();
    _micTrack?.stop();
    _mic?.dispose();
    _remote.dispose();
    _ipCtl.dispose();
    _pinCtl.dispose();
    _portrait();
    super.dispose();
  }

  Widget _controls({required bool dark}) => Wrap(
        alignment: WrapAlignment.spaceEvenly,
        spacing: 6,
        runSpacing: 6,
        children: [
          CtlButton(
              icon: _talking ? Icons.mic : Icons.mic_off,
              label: 'ميكروفون',
              active: _talking,
              dark: dark,
              onTap: _toggleMic),
          CtlButton(
              icon: _muted ? Icons.volume_off : Icons.volume_up,
              label: 'الصوت',
              active: _muted,
              dark: dark,
              onTap: _toggleMute),
          CtlButton(
              icon: _remoteRec ? Icons.stop : Icons.fiber_manual_record,
              label: _remoteRec ? 'إيقاف' : 'تسجيل',
              active: _remoteRec,
              dark: dark,
              onTap: _toggleRec),
          CtlButton(
              icon: Icons.photo_camera_rounded,
              label: 'لقطة',
              dark: dark,
              onTap: _shot),
          CtlButton(
              icon: Icons.cameraswitch,
              label: 'قلب',
              dark: dark,
              onTap: _switchCam),
          CtlButton(
              icon: _torch ? Icons.flashlight_on : Icons.flashlight_off,
              label: 'فلاش',
              active: _torch,
              dark: dark,
              onTap: _toggleTorch),
          CtlButton(
              icon: Icons.nightlight_round,
              label: 'ليلي',
              active: _night > 0,
              dark: dark,
              onTap: _tools),
          CtlButton(
              icon: _wide ? Icons.fullscreen_exit : Icons.fullscreen,
              label: _wide ? 'تصغير' : 'عريض',
              dark: dark,
              onTap: () => _setWide(!_wide)),
        ],
      );

  Widget _field(TextEditingController c, String label, String hint,
          IconData icon, VoidCallback onTap, List<TextInputFormatter> fmt) =>
      TextField(
        controller: c,
        keyboardType: TextInputType.none, // we use our own keypad
        textDirection: TextDirection.ltr,
        onTap: onTap,
        inputFormatters: fmt,
        style: const TextStyle(fontSize: 18, letterSpacing: 1),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: Icon(icon, size: 20),
          filled: true,
          fillColor: kBg,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: const BorderSide(color: kAccent, width: 1.5)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (_wide) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(children: [
          Positioned.fill(
              child: widget.screen ? _screenArea() : _videoView()),
          Positioned(top: 8, left: 12, child: SafeArea(child: _hud())),
          Positioned(
            top: 8,
            right: 12,
            child: SafeArea(
              child: Row(children: [
                Pill(
                    color: _isConnected ? kRed : Colors.grey,
                    text: _isConnected ? 'LIVE' : _status),
                if (_remoteRec) ...[
                  const SizedBox(width: 8),
                  const Pill(color: kRed, text: 'REC'),
                ],
              ]),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 8,
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 60),
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0x99000000),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: widget.screen
                    ? _screenControls(dark: true)
                    : _controls(dark: true),
              ),
            ),
          ),
        ]),
      );
    }

    return Scaffold(
      appBar: AppBar(
          title: Text(widget.screen ? 'شاشة الهاتف' : 'وضع المشاهدة')),
      body: Column(children: [
        // ── connection card ──
        Container(
          margin: const EdgeInsets.fromLTRB(14, 4, 14, 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: kSurface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white10),
          ),
          child: Column(children: [
            Row(children: [
              Expanded(
                flex: 3,
                child: _field(
                  _ipCtl,
                  'IP الكاميرا',
                  '192.168.1.20',
                  Icons.wifi,
                  () => setState(() => _pinActive = false),
                  [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: _field(
                  _pinCtl,
                  'PIN',
                  '••••••',
                  Icons.lock_outline,
                  () => setState(() => _pinActive = true),
                  [FilteringTextInputFormatter.digitsOnly],
                ),
              ),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: _scanning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search_rounded),
                  label: const Text('بحث'),
                  onPressed: _scanning ? null : _scan,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: const Icon(Icons.qr_code_scanner_rounded),
                  label: const Text('QR'),
                  onPressed: _scanQr,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(46),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('اتصال'),
                  onPressed: _connect,
                ),
              ),
            ]),
            if (_found.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  for (final ip in _found)
                    ActionChip(
                      avatar: const Icon(Icons.videocam_rounded, size: 18),
                      label: Text(ip),
                      backgroundColor: kSurface2,
                      onPressed: () => setState(() {
                        _ipCtl.text = ip;
                        _pinActive = true;
                      }),
                    ),
                ],
              ),
            ],
          ]),
        ),

        // ── status ──
        if (_status.isNotEmpty)
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: _isConnected ? kGreen : Colors.amber,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(_status,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 13, color: Colors.white70)),
            ),
            if (_wantLive && !_isConnected)
              TextButton(
                onPressed: _stopRetry,
                child: const Text('إيقاف'),
              ),
          ]),

        // ── video ──
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(14, 8, 14, 0),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: Colors.white10),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: Stack(fit: StackFit.expand, children: [
                widget.screen ? _screenArea() : _videoView(),
                if (!widget.screen && _remote.srcObject == null)
                  Container(
                    color: Colors.black,
                    child: const Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.videocam_off_outlined,
                            size: 40, color: Colors.white24),
                        SizedBox(height: 8),
                        Text('لا يوجد بث',
                            style: TextStyle(color: Colors.white38)),
                      ]),
                    ),
                  ),
                if (_isConnected)
                  const Positioned(
                      top: 10, right: 10, child: Pill(color: kRed, text: 'LIVE')),
                if (_remoteRec)
                  const Positioned(
                      top: 10, left: 10, child: Pill(color: kRed, text: 'REC')),
                Positioned(bottom: 8, left: 8, right: 8, child: _hud()),
              ]),
            ),
          ),
        ),

        // ── controls ──
        Container(
          margin: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: kSurface,
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: Colors.white10),
          ),
          child: widget.screen
              ? _screenControls(dark: false)
              : _controls(dark: false),
        ),
        if (!_isConnected && !_wantLive)
          SafeArea(
            top: false,
            child: Keypad(onKey: _key, onBack: _back),
          ),
      ]),
    );
  }
}

// ───────────────────────── Multi-camera grid (2×2) ─────────────────────────
class MultiViewPage extends StatefulWidget {
  const MultiViewPage({super.key});
  @override
  State<MultiViewPage> createState() => _MultiViewPageState();
}

class _MultiViewPageState extends State<MultiViewPage> {
  List<Map<String, dynamic>> _cams = [];
  bool _paused = false;
  bool _wide = false;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    loadSettings().then((s) {
      final l = s['cams'];
      if (l is List && mounted) {
        setState(() => _cams = [
              for (final c in l) Map<String, dynamic>.from(c as Map),
            ]);
      }
    });
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _portrait();
    super.dispose();
  }

  void _save() => saveSettings({'cams': _cams});

  Future<void> _add() async {
    final c = await showDialog<Map<String, dynamic>>(
        context: context, builder: (_) => const _AddCamDialog());
    if (c == null || !mounted) return;
    setState(() => _cams.add(c));
    _save();
  }

  void _remove(int i) {
    setState(() => _cams.removeAt(i));
    _save();
  }

  Future<void> _open(Map<String, dynamic> c) async {
    // one viewer per camera: pause the tiles while the full viewer is open
    setState(() => _paused = true);
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => ViewerPage(
                  initialIp: '${c['ip']}',
                  initialPin: '${c['pin']}',
                  autoConnect: true,
                )));
    if (!mounted) return;
    if (_wide) {
      await _landscape();
    } else {
      await _portrait();
    }
    setState(() => _paused = false);
  }

  Future<void> _toggleWide() async {
    if (_wide) {
      await _portrait();
    } else {
      await _landscape();
    }
    if (mounted) setState(() => _wide = !_wide);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('عدة كاميرات'),
          actions: [
            IconButton(
              icon: Icon(_wide
                  ? Icons.stay_current_portrait_rounded
                  : Icons.stay_current_landscape_rounded),
              onPressed: _toggleWide,
            ),
            IconButton(
              icon: const Icon(Icons.add_rounded),
              onPressed: _cams.length >= 4 ? null : _add,
            ),
          ],
        ),
        body: _cams.isEmpty
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.grid_view_rounded,
                      size: 56, color: Colors.white24),
                  const SizedBox(height: 12),
                  const Text('أضف حتى 4 كاميرات وشاهدها معاً',
                      style: TextStyle(color: Colors.white60)),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('إضافة كاميرا'),
                    onPressed: _add,
                  ),
                ]),
              )
            : Padding(
                padding: const EdgeInsets.all(10),
                child: GridView.count(
                  crossAxisCount: 2,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 16 / 9,
                  children: [
                    for (var i = 0; i < _cams.length; i++)
                      _paused
                          ? Container(
                              decoration: BoxDecoration(
                                color: Colors.black,
                                borderRadius: BorderRadius.circular(14),
                              ),
                            )
                          : _CamTile(
                              key: ValueKey('${_cams[i]['ip']}|${_cams[i]['pin']}|$i'),
                              cam: _cams[i],
                              onOpen: () => _open(_cams[i]),
                              onRemove: () => _remove(i),
                            ),
                  ],
                ),
              ),
      );
}

class _AddCamDialog extends StatefulWidget {
  const _AddCamDialog();
  @override
  State<_AddCamDialog> createState() => _AddCamDialogState();
}

class _AddCamDialogState extends State<_AddCamDialog> {
  final _name = TextEditingController();
  final _ip = TextEditingController();
  final _pin = TextEditingController();
  bool _scanning = false;
  List<String> _found = [];

  @override
  void dispose() {
    _name.dispose();
    _ip.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _found = [];
    });
    final r = await scanLan();
    if (!mounted) return;
    setState(() {
      _scanning = false;
      _found = r;
    });
  }

  Future<void> _qr() async {
    final v = await Navigator.push<String>(
        context, MaterialPageRoute(builder: (_) => const QrScanPage()));
    if (v == null || !mounted) return;
    final p = v.split('|');
    if (p.length < 4) return;
    setState(() {
      _ip.text = p[1];
      _pin.text = p[3];
    });
  }

  InputDecoration _dec(String label) => InputDecoration(
        labelText: label,
        filled: true,
        fillColor: kBg,
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: kSurface,
        title: const Text('إضافة كاميرا'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: _name, decoration: _dec('الاسم (مثلاً: المدخل)')),
            const SizedBox(height: 10),
            TextField(
              controller: _ip,
              keyboardType: TextInputType.url,
              textDirection: TextDirection.ltr,
              decoration: _dec('IP الكاميرا'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _pin,
              keyboardType: TextInputType.number,
              textDirection: TextDirection.ltr,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: _dec('PIN'),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: _scanning
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search_rounded, size: 18),
                  label: const Text('بحث'),
                  onPressed: _scanning ? null : _scan,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                  label: const Text('QR'),
                  onPressed: _qr,
                ),
              ),
            ]),
            if (_found.isNotEmpty)
              Wrap(spacing: 6, children: [
                for (final ip in _found)
                  ActionChip(
                    label: Text(ip),
                    onPressed: () => setState(() => _ip.text = ip),
                  ),
              ]),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء')),
          FilledButton(
            onPressed: () {
              final ip = _ip.text.trim();
              if (ip.isEmpty) return;
              Navigator.pop(context, <String, dynamic>{
                'name': _name.text.trim().isEmpty ? ip : _name.text.trim(),
                'ip': ip,
                'pin': _pin.text.trim(),
              });
            },
            child: const Text('إضافة'),
          ),
        ],
      );
}

/// One live camera inside the grid (view only, muted by default).
class _CamTile extends StatefulWidget {
  const _CamTile({
    super.key,
    required this.cam,
    required this.onOpen,
    required this.onRemove,
  });
  final Map<String, dynamic> cam;
  final VoidCallback onOpen;
  final VoidCallback onRemove;
  @override
  State<_CamTile> createState() => _CamTileState();
}

class _CamTileState extends State<_CamTile> {
  final _r = RTCVideoRenderer();
  RTCPeerConnection? _pc;
  WebSocket? _ws;
  Timer? _retry;
  bool _alive = true;
  bool _busy = false;
  bool _fatal = false;
  bool _live = false;
  bool _muted = true;
  int _n = 0;
  String _msg = 'جاري الاتصال...';
  Map _h = {};

  String get _ip => '${widget.cam['ip']}';
  String get _pin => '${widget.cam['pin']}';

  @override
  void initState() {
    super.initState();
    _r.initialize().then((_) => _connect());
  }

  String _why(Object e) {
    if (e == 'denied') return 'الكاميرا رفضت (PIN أو الجاهزية الدائمة)';
    if (e == 'unreachable') return 'الكاميرا غير متاحة';
    if (e == 'timeout') return 'الكاميرا لا تستجيب';
    if (e is SocketException) return 'تعذّر الاتصال';
    if (e is TimeoutException) return 'انتهت المهلة';
    return 'فشل الاتصال';
  }

  void _lost(String why) {
    if (!_alive || _fatal) return;
    if (_retry?.isActive == true) return;
    _n++;
    final secs = min(10, 1 + _n * 2);
    if (mounted) {
      setState(() {
        _live = false;
        _msg = '$why — إعادة بعد $secs ث';
      });
    }
    _retry = Timer(Duration(seconds: secs), () {
      final p = _pc;
      final w = _ws;
      _pc = null;
      _ws = null;
      p?.close();
      w?.close();
      _connect();
    });
  }

  Future<void> _connect() async {
    if (!_alive || _busy) return;
    _busy = true;
    try {
      await applyNetConfig();
      if (mounted) setState(() => _msg = 'جاري الاتصال...');
      if (!await portOpen(_ip, kPort)) {
        if (mounted) setState(() => _msg = 'إيقاظ الكاميرا...');
        final w = await wakeCamera(_ip, _pin);
        if (w != 'ok') throw w == 'denied' ? 'denied' : 'unreachable';
        var up = false;
        for (var i = 0; i < 25 && !up && _alive; i++) {
          await Future.delayed(const Duration(seconds: 1));
          up = await portOpen(_ip, kPort);
        }
        if (!up) throw 'timeout';
      }
      if (!_alive) return;
      final op = _pc;
      final ow = _ws;
      _pc = null;
      _ws = null;
      await op?.close();
      ow?.close();
      final ws = _ws = await WebSocket.connect('ws://$_ip:$kPort')
          .timeout(const Duration(seconds: 5));
      final pc = _pc = await createPeerConnection(kPcConfig);
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      pc.onTrack = (e) {
        if (e.track.kind == 'audio') e.track.enabled = !_muted;
        if (e.track.kind == 'video' && e.streams.isNotEmpty && mounted) {
          setState(() => _r.srcObject = e.streams.first);
        }
      };
      pc.onConnectionState = (s) {
        if (!_alive || !identical(_pc, pc)) return;
        final live = s == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
        if (live) _n = 0;
        if (mounted) setState(() => _live = live);
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            s == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
          _lost('انقطع');
        }
      };
      ws.listen((m) async {
        if (m is! String) return;
        final d = jsonDecode(m);
        switch (d['type']) {
          case 'answer':
            await pc.setRemoteDescription(
                RTCSessionDescription(d['sdp'] as String, 'answer'));
            break;
          case 'health':
            if (mounted) setState(() => _h = Map<String, dynamic>.from(d));
            break;
          case 'denied':
            _fatal = true;
            if (mounted) setState(() => _msg = 'PIN غير صحيح');
            break;
          case 'locked':
            _fatal = true;
            if (mounted) setState(() => _msg = 'محاولات كثيرة — انتظر 5 دقائق');
            break;
        }
      }, onDone: () {
        if (identical(_ws, ws)) _lost('انقطع');
      });
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await waitIceGathered(pc);
      final l = await pc.getLocalDescription();
      ws.add(jsonEncode({'type': 'offer', 'sdp': l!.sdp, 'pin': _pin}));
    } catch (e) {
      _lost(_why(e));
    } finally {
      _busy = false;
    }
  }

  void _toggleMute() {
    setState(() => _muted = !_muted);
    for (final t in _r.srcObject?.getAudioTracks() ?? <MediaStreamTrack>[]) {
      t.enabled = !_muted;
    }
    if (!_muted) {
      Helper.setSpeakerphoneOn(true).catchError((_) {});
    }
  }

  @override
  void dispose() {
    _alive = false;
    _retry?.cancel();
    _pc?.close();
    _ws?.close();
    _r.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bat = _h['bat'];
    return GestureDetector(
      onTap: widget.onOpen,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(fit: StackFit.expand, children: [
          Container(color: Colors.black),
          if (_r.srcObject != null)
            RTCVideoView(_r,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
          if (!_live)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.videocam_off_outlined,
                      size: 26, color: Colors.white24),
                  const SizedBox(height: 4),
                  Text(_msg,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 10, color: Colors.white54)),
                ]),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: const Color(0x99000000),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              child: Row(children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: _live ? kGreen : Colors.amber,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text('${widget.cam['name']}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11, color: Colors.white)),
                ),
                if (bat is num)
                  Text('${bat.toInt()}%',
                      style: TextStyle(
                          fontSize: 10,
                          color: bat <= 20 ? kRed : Colors.white70)),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _toggleMute,
                  child: Icon(_muted ? Icons.volume_off : Icons.volume_up,
                      size: 16, color: Colors.white70),
                ),
              ]),
            ),
          ),
          Positioned(
            top: 2,
            left: 2,
            child: GestureDetector(
              onTap: widget.onRemove,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close_rounded, size: 16, color: Colors.white54),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

```