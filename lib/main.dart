import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/widgets.dart' as w show Text;
import 'package:flutter/services.dart';
import 'package:battery_plus/battery_plus.dart' show Battery, BatteryState;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter_tts/flutter_tts.dart' show FlutterTts;
import 'package:gal/gal.dart' show Gal;
import 'package:local_auth/local_auth.dart'
    show AuthenticationOptions, LocalAuthentication;
import 'package:share_plus/share_plus.dart' show Share, XFile;
import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;
import 'package:mobile_scanner/mobile_scanner.dart'
    show BarcodeCapture, BarcodeFormat, MobileScanner, MobileScannerController;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart' show QrImageView, QrVersions;
import 'package:quick_actions/quick_actions.dart';

import 'person.dart';
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

final GlobalKey<NavigatorState> kNav = GlobalKey<NavigatorState>();
final ValueNotifier<int> kThumbRev = ValueNotifier<int>(0);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadTls();
  applyUiPrefs(await loadSettings());
  runApp(ValueListenableBuilder<int>(
    valueListenable: kUiRev,
    builder: (_, __, ___) => MaterialApp(
      navigatorKey: kNav,
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
      builder: uiShell,
      home: const Home(),
    ),
  ));
}

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

// ───────────────── TLS (signalling, library, PIN) ─────────────────
// The build embeds one certificate + key (assets/tls). Both phones carry the
// same identity, so a client accepts only a server presenting that exact cert.
String? _tlsCert;
String? _tlsKey;
List<int>? _tlsDer;
bool get kTls => _tlsDer != null && _tlsKey != null;

Future<void> loadTls() async {
  try {
    final c = (await rootBundle.loadString('assets/tls/cert.pem')).trim();
    final k = (await rootBundle.loadString('assets/tls/key.pem')).trim();
    if (!c.contains('BEGIN CERTIFICATE') || !k.contains('PRIVATE KEY')) return;
    final b64 = c
        .split('\n')
        .where((l) => !l.startsWith('-----'))
        .join()
        .replaceAll('\r', '')
        .trim();
    _tlsDer = base64Decode(b64);
    _tlsCert = c;
    _tlsKey = k;
  } catch (_) {
    _tlsDer = null;
  }
}

SecurityContext? tlsServerContext() {
  if (!kTls) return null;
  return SecurityContext()
    ..useCertificateChainBytes(utf8.encode(_tlsCert!))
    ..usePrivateKeyBytes(utf8.encode(_tlsKey!));
}

bool _sameCert(List<int> der) {
  final a = _tlsDer;
  if (a == null || a.length != der.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != der[i]) return false;
  }
  return true;
}

HttpClient tlsClient() => HttpClient()
  ..badCertificateCallback =
      (X509Certificate cert, String host, int port) => _sameCert(cert.der);

Future<WebSocket> openWs(String ip) => kTls
    ? WebSocket.connect('wss://$ip:$kPort', customClient: tlsClient())
    : WebSocket.connect('ws://$ip:$kPort');

/// Long-press shortcuts on the app icon: one per saved camera (max 4).
Future<void> refreshShortcuts() async {
  try {
    final q = QuickActions();
    final s = await loadSettings();
    final l = s['cams'];
    final items = <ShortcutItem>[];
    if (l is List) {
      for (var i = 0; i < l.length && i < 4; i++) {
        items.add(ShortcutItem(
            type: 'cam$i', localizedTitle: '${(l[i] as Map)['name']}'));
      }
    }
    await q.setShortcutItems(items);
  } catch (_) {}
}

void initShortcuts() {
  try {
    final q = QuickActions();
    q.initialize((type) async {
      final s = await loadSettings();
      final l = s['cams'];
      final i = int.tryParse(type.replaceFirst('cam', ''));
      if (l is! List || i == null || i < 0 || i >= l.length) return;
      final c = Map<String, dynamic>.from(l[i] as Map);
      kNav.currentState?.push(MaterialPageRoute(
          builder: (_) => ViewerPage(
                initialIp: '${c['ip']}',
                initialPin: '${c['pin']}',
                autoConnect: true,
              )));
    });
  } catch (_) {}
  refreshShortcuts();
}

/// Last picture seen from the camera(s), shown on the home cards.
class ThumbPreview extends StatefulWidget {
  const ThumbPreview({
    super.key,
    required this.multi,
    required this.icon,
    required this.color,
    required this.tint,
  });
  final bool multi;
  final IconData icon;
  final Color color;
  final Color tint;
  @override
  State<ThumbPreview> createState() => _ThumbPreviewState();
}

class _ThumbPreviewState extends State<ThumbPreview> {
  List<Uint8List> _imgs = [];

  @override
  void initState() {
    super.initState();
    _load();
    kThumbRev.addListener(_load);
  }

  @override
  void dispose() {
    kThumbRev.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final s = await loadSettings();
    final ips = <String>[];
    if (widget.multi) {
      final l = s['cams'];
      if (l is List) {
        for (final c in l.take(4)) {
          ips.add('${(c as Map)['ip']}');
        }
      }
    } else {
      final ip = s['ip'];
      if (ip is String && ip.isNotEmpty) ips.add(ip);
    }
    final out = <Uint8List>[];
    for (final ip in ips) {
      final f = await thumbFile(ip);
      if (await f.exists()) out.add(await f.readAsBytes());
    }
    if (mounted) setState(() => _imgs = out);
  }

  Widget _img(Uint8List b) => Image.memory(b,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      errorBuilder: (_, __, ___) => const SizedBox());

  @override
  Widget build(BuildContext context) => Container(
        width: 56,
        height: 56,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: widget.tint,
          borderRadius: BorderRadius.circular(16),
        ),
        child: _imgs.isEmpty
            ? Icon(widget.icon, color: widget.color, size: 30)
            : _imgs.length == 1
                ? _img(_imgs[0])
                : GridView.count(
                    crossAxisCount: 2,
                    padding: EdgeInsets.zero,
                    mainAxisSpacing: 1,
                    crossAxisSpacing: 1,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [for (final b in _imgs) _img(b)],
                  ),
      );
}

// ───────────────── External notifications (Telegram / ntfy) ─────────────────
String _b64Header(String s) => '=?UTF-8?B?${base64Encode(utf8.encode(s))}?=';

Future<bool> _tgSend(
    String token, String chat, String text, Uint8List? img) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    if (img == null) {
      final req = await c
          .postUrl(Uri.parse('https://api.telegram.org/bot$token/sendMessage'));
      req.headers.contentType = ContentType.json;
      final body = utf8.encode(jsonEncode({'chat_id': chat, 'text': text}));
      req.contentLength = body.length;
      req.add(body);
      final res = await req.close().timeout(const Duration(seconds: 15));
      await res.drain();
      return res.statusCode == 200;
    }
    final b = '----lancam${DateTime.now().microsecondsSinceEpoch}';
    final bb = BytesBuilder();
    void field(String n, String v) => bb.add(utf8.encode(
        '--$b\r\nContent-Disposition: form-data; name="$n"\r\n\r\n$v\r\n'));
    field('chat_id', chat);
    field('caption', text);
    bb.add(utf8.encode(
        '--$b\r\nContent-Disposition: form-data; name="photo"; filename="snap.png"\r\nContent-Type: image/png\r\n\r\n'));
    bb.add(img);
    bb.add(utf8.encode('\r\n--$b--\r\n'));
    final data = bb.takeBytes();
    final req = await c
        .postUrl(Uri.parse('https://api.telegram.org/bot$token/sendPhoto'));
    req.headers.set('content-type', 'multipart/form-data; boundary=$b');
    req.contentLength = data.length;
    req.add(data);
    final res = await req.close().timeout(const Duration(seconds: 25));
    await res.drain();
    return res.statusCode == 200;
  } catch (_) {
    return false;
  } finally {
    c.close(force: true);
  }
}

Future<bool> _ntfySend(String server, String topic, String title, String text,
    Uint8List? img) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final base = server.trim().isEmpty
        ? 'https://ntfy.sh'
        : server.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/$topic');
    final HttpClientRequest req =
        img == null ? await c.postUrl(uri) : await c.putUrl(uri);
    req.headers.set('Title', _b64Header(title));
    req.headers.set('Priority', '4');
    req.headers.set('Tags', 'rotating_light');
    if (img != null) {
      req.headers.set('Message', _b64Header(text));
      req.headers.set('Filename', 'snap.png');
      req.contentLength = img.length;
      req.add(img);
    } else {
      final body = utf8.encode(text);
      req.contentLength = body.length;
      req.add(body);
    }
    final res = await req.close().timeout(const Duration(seconds: 25));
    await res.drain();
    return res.statusCode == 200;
  } catch (_) {
    return false;
  } finally {
    c.close(force: true);
  }
}

bool pushConfigured(Map s) {
  final tok = '${s['tgToken'] ?? ''}'.trim();
  final chat = '${s['tgChat'] ?? ''}'.trim();
  final topic = '${s['ntfyTopic'] ?? ''}'.trim();
  return (tok.isNotEmpty && chat.isNotEmpty) || topic.isNotEmpty;
}

/// null = nothing configured, true = delivered, false = failed (retry later).
Future<bool?> sendPush(String title, String text, {Uint8List? image}) async {
  final s = await loadSettings();
  if (!pushConfigured(s)) return null;
  final tok = '${s['tgToken'] ?? ''}'.trim();
  final chat = '${s['tgChat'] ?? ''}'.trim();
  final topic = '${s['ntfyTopic'] ?? ''}'.trim();
  var ok = true;
  if (tok.isNotEmpty && chat.isNotEmpty) {
    ok = await _tgSend(tok, chat, '$title\n$text', image) && ok;
  }
  if (topic.isNotEmpty) {
    ok = await _ntfySend('${s['ntfyUrl'] ?? ''}', topic, title, text, image) && ok;
  }
  return ok;
}

class _Pending {
  _Pending(this.title, this.text, this.image);
  final String title;
  final String text;
  final Uint8List? image;
}

/// Store-and-forward: alerts that could not be delivered (no internet) are
/// retried every 30 s while the camera app is running.
class PushQueue {
  static final List<_Pending> _q = [];
  static bool _busy = false;

  static Future<void> send(String title, String text, {Uint8List? image}) async {
    final r = await sendPush(title, text, image: image);
    if (r == false) {
      _q.add(_Pending(title, text, image));
      if (_q.length > 10) _q.removeAt(0);
    }
  }

  static Future<void> flush() async {
    if (_busy || _q.isEmpty) return;
    _busy = true;
    try {
      while (_q.isNotEmpty) {
        final p = _q.first;
        final r = await sendPush(p.title, p.text, image: p.image);
        if (r == false) break;
        _q.removeAt(0);
      }
    } finally {
      _busy = false;
    }
  }
}

/// Finds the chat id of the last message sent to the bot.
Future<String?> tgFindChat(String token) async {
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
  try {
    final req = await c
        .getUrl(Uri.parse('https://api.telegram.org/bot$token/getUpdates'));
    final res = await req.close().timeout(const Duration(seconds: 15));
    final body = await res.transform(utf8.decoder).join();
    final r = (jsonDecode(body) as Map)['result'] as List;
    for (var i = r.length - 1; i >= 0; i--) {
      final m = r[i]['message'] ?? r[i]['channel_post'];
      if (m != null && m['chat'] != null) return '${m['chat']['id']}';
    }
  } catch (_) {
  } finally {
    c.close(force: true);
  }
  return null;
}

bool wdConfigured(Map s) => '${s['wdUrl'] ?? ''}'.trim().isNotEmpty;

/// Uploads a finished recording to a WebDAV server (Nextcloud, NAS...).
Future<bool> webdavPut(File f) async {
  final s = await loadSettings();
  final url = '${s['wdUrl'] ?? ''}'.trim();
  if (url.isEmpty) return true;
  final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final name = f.path.split('/').last;
    final uri = Uri.parse('${url.replaceAll(RegExp(r'/+$'), '')}/$name');
    final req = await c.putUrl(uri);
    final u = '${s['wdUser'] ?? ''}';
    final p = '${s['wdPass'] ?? ''}';
    if (u.isNotEmpty) {
      req.headers.set(
          'Authorization', 'Basic ${base64Encode(utf8.encode('$u:$p'))}');
    }
    req.contentLength = await f.length();
    await req.addStream(f.openRead());
    final res = await req.close();
    await res.drain();
    return res.statusCode >= 200 && res.statusCode < 300;
  } catch (_) {
    return false;
  } finally {
    c.close(force: true);
  }
}

// ───────────────── Daily summary ─────────────────
class DaySummary {
  DaySummary(this.motion, this.sound, this.hours, this.times);
  final int motion;
  final int sound;
  final List<int> hours;
  final List<String> times;
  int get total => motion + sound;
  int get busiest {
    var b = 0;
    for (var i = 1; i < 24; i++) {
      if (hours[i] > hours[b]) b = i;
    }
    return b;
  }

  String text(String title) {
    if (total == 0) return '$title: لا توجد أحداث.';
    return '$title: $total حدث (حركة $motion، صوت $sound). '
        'أكثر ساعة نشاطاً ${two(busiest)}:00 (${hours[busiest]} حدث).';
  }
}

DaySummary summarizeEvents(Iterable<String> names, DateTime day) {
  final re = RegExp(
      r'evt_(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})_(motion|sound)');
  var m = 0;
  var s = 0;
  final hours = List<int>.filled(24, 0);
  final times = <String>[];
  for (final n in names) {
    final x = re.firstMatch(n);
    if (x == null) continue;
    if (int.parse(x.group(1)!) != day.year ||
        int.parse(x.group(2)!) != day.month ||
        int.parse(x.group(3)!) != day.day) {
      continue;
    }
    if (x.group(7) == 'sound') {
      s++;
    } else {
      m++;
    }
    hours[int.parse(x.group(4)!)]++;
    times.add('${x.group(4)}:${x.group(5)}');
  }
  times.sort();
  return DaySummary(m, s, hours, times);
}

// ───────────────── "Why doesn't it work?" ─────────────────
class _DiagItem {
  _DiagItem(this.title, this.ok, this.detail, {this.fix, this.fixLabel});
  final String title;
  final bool? ok; // null = information only
  final String detail;
  final VoidCallback? fix;
  final String? fixLabel;
}

class DiagPage extends StatefulWidget {
  const DiagPage({super.key});
  @override
  State<DiagPage> createState() => _DiagPageState();
}

class _DiagPageState extends State<DiagPage> {
  List<_DiagItem> _items = [];
  List<_DiagItem> _conn = [];
  final _ipCtl = TextEditingController();
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    loadSettings().then((s) {
      if (mounted) _ipCtl.text = '${s['ip'] ?? ''}';
    });
    _run();
  }

  @override
  void dispose() {
    _ipCtl.dispose();
    super.dispose();
  }

  Future<bool> _internet() async {
    try {
      final s = await Socket.connect('1.1.1.1', 443,
          timeout: const Duration(seconds: 3));
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _run() async {
    setState(() => _busy = true);
    final out = <_DiagItem>[];
    final ip = await localIp();
    out.add(_DiagItem('الشبكة المحلية (واي فاي)', ip != null,
        ip ?? 'غير متصل بشبكة. اتصل بالواي فاي نفسه على الهاتفين.'));
    final cam = await Permission.camera.status;
    out.add(_DiagItem('إذن الكاميرا', cam.isGranted,
        cam.isGranted ? 'مسموح' : 'غير مسموح (مطلوب لجهاز الكاميرا)',
        fixLabel: 'السماح', fix: () async {
      final r = await Permission.camera.request();
      if (!r.isGranted) await openAppSettings();
      _run();
    }));
    final mic = await Permission.microphone.status;
    out.add(_DiagItem('إذن الميكروفون', mic.isGranted,
        mic.isGranted ? 'مسموح' : 'غير مسموح (الصوت لن يعمل)',
        fixLabel: 'السماح', fix: () async {
      final r = await Permission.microphone.request();
      if (!r.isGranted) await openAppSettings();
      _run();
    }));
    if (Platform.isAndroid) {
      try {
        final m = await _svc.invokeMethod<Map>('status');
        final sc = await _svc.invokeMethod<Map>('screenInfo');
        out.add(_DiagItem(
            'الخدمة في الخلفية',
            m?['running'] == true,
            m?['running'] == true
                ? 'تعمل'
                : 'متوقفة. فعّل "جاهزية دائمة" في وضع الكاميرا.'));
        out.add(_DiagItem('منفذ الإيقاظ $kWakePort', m?['listening'] == true,
            m?['listening'] == true ? 'يستمع' : 'لا يستمع (الجاهزية الدائمة مطفأة)'));
        out.add(_DiagItem(
            'استثناء توفير البطارية',
            m?['battery'] == true,
            m?['battery'] == true
                ? 'مستثنى'
                : 'النظام قد يقتل التطبيق في الخلفية',
            fixLabel: 'استثناء',
            fix: () async {
              try {
                await _svc.invokeMethod('battery');
              } catch (_) {}
              Future.delayed(const Duration(seconds: 2), _run);
            }));
        out.add(_DiagItem(
            'الظهور فوق التطبيقات',
            m?['overlay'] == true,
            m?['overlay'] == true
                ? 'مسموح'
                : 'مطلوب لإيقاظ الكاميرا وهي مغلقة',
            fixLabel: 'السماح',
            fix: () async {
              try {
                await _svc.invokeMethod('overlay');
              } catch (_) {}
              Future.delayed(const Duration(seconds: 2), _run);
            }));
        out.add(_DiagItem(
            'التحكم في الشاشة (إمكانية الوصول)',
            sc?['control'] == true,
            sc?['control'] == true
                ? 'مفعّل'
                : 'اختياري: يلزم لتحكم المشاهد بالشاشة. افتح الإعدادات ← التطبيقات ← LAN Cam ← ⋮ ← السماح بالإعدادات المقيّدة أولاً.',
            fixLabel: 'فتح',
            fix: () async {
              try {
                await _svc.invokeMethod('openAccessibility');
              } catch (_) {}
            }));
      } catch (_) {}
    }
    out.add(_DiagItem('تشفير TLS', kTls,
        kTls ? 'مفعّل' : 'غير مضمّن في هذا الإصدار (الاتصال غير مشفّر)'));
    final s = await loadSettings();
    final net = await _internet();
    if (pushConfigured(s)) {
      out.add(_DiagItem('إشعارات خارجية (تيليغرام / ntfy)', net,
          net ? 'مُعدّة والإنترنت متاح' : 'مُعدّة لكن لا يوجد إنترنت الآن'));
    } else {
      out.add(_DiagItem('إشعارات خارجية (تيليغرام / ntfy)', null,
          'غير مُعدّة (الإعدادات ← إشعارات خارجية)'));
    }
    if (!mounted) return;
    setState(() {
      _items = out;
      _busy = false;
    });
  }

  Future<void> _test() async {
    final ip = _ipCtl.text.trim();
    if (ip.isEmpty) return;
    setState(() => _conn = []);
    final main = await portOpen(ip, kPort);
    final wake = await portOpen(ip, kWakePort);
    final out = <_DiagItem>[
      _DiagItem(
          'منفذ الكاميرا $kPort',
          main,
          main
              ? 'الكاميرا تعمل وتستقبل'
              : 'لا يوجد رد: الكاميرا مغلقة أو العنوان خطأ أو شبكة مختلفة'),
      _DiagItem(
          'منفذ الإيقاظ $kWakePort',
          wake,
          wake
              ? 'الجاهزية الدائمة تعمل (يمكن إيقاظها)'
              : main
                  ? 'غير مفعّل (غير مطلوب والكاميرا شغّالة)'
                  : 'الجاهزية الدائمة غير مفعّلة على الكاميرا'),
    ];
    if (!mounted) return;
    setState(() => _conn = out);
  }

  Widget _row(_DiagItem it) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(
              it.ok == null
                  ? Icons.info_outline_rounded
                  : (it.ok! ? Icons.check_circle_rounded : Icons.cancel_rounded),
              color: it.ok == null
                  ? Colors.white38
                  : (it.ok! ? kGreen : kRed),
              size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(it.title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(it.detail,
                  style: const TextStyle(fontSize: 12, color: Colors.white60)),
            ]),
          ),
          if (it.ok != true && it.fix != null)
            TextButton(onPressed: it.fix, child: Text(it.fixLabel ?? 'إصلاح')),
        ]),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('لماذا لا يعمل؟'),
          actions: [
            IconButton(icon: const Icon(Icons.refresh_rounded), onPressed: _run),
          ],
        ),
        body: ListView(padding: const EdgeInsets.all(14), children: [
          const Text('هذا الهاتف',
              style: TextStyle(fontWeight: FontWeight.w800, color: Colors.white70)),
          const SizedBox(height: 8),
          if (_busy) const Center(child: CircularProgressIndicator()),
          for (final it in _items) _row(it),
          const SizedBox(height: 16),
          const Text('اختبار الاتصال بكاميرا',
              style: TextStyle(fontWeight: FontWeight.w800, color: Colors.white70)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _ipCtl,
                keyboardType: TextInputType.url,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(
                  hintText: 'IP الكاميرا',
                  filled: true,
                  fillColor: kSurface,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _test, child: const Text('فحص')),
          ]),
          const SizedBox(height: 10),
          for (final it in _conn) _row(it),
        ]),
      );
}

// ───────────────── First-run setup wizard ─────────────────
class SetupWizard extends StatefulWidget {
  const SetupWizard({super.key});
  @override
  State<SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends State<SetupWizard> {
  int _step = 0;
  String _role = ''; // camera | viewer
  String _ip = '';
  String _pin = '';
  Map _st = {};

  Future<void> _refresh() async {
    if (!Platform.isAndroid) return;
    try {
      final m = await _svc.invokeMethod<Map>('status');
      if (mounted) setState(() => _st = m ?? {});
    } catch (_) {}
  }

  List<String> get _steps => _role == 'camera'
      ? ['role', 'perm', if (Platform.isAndroid) 'bg', 'alerts', 'pair']
      : ['role', 'pair'];

  Future<void> _finish() async {
    await saveSettings({'setupDone': true});
    if (mounted) Navigator.pop(context);
  }

  void _next() {
    if (_step + 1 >= _steps.length) {
      _finish();
    } else {
      setState(() => _step++);
      if (_steps[_step] == 'pair' && _role == 'camera') _prepPair();
      if (_steps[_step] == 'bg') _refresh();
    }
  }

  Future<void> _prepPair() async {
    final s = await loadSettings();
    var pin = (s['campin'] as String?) ?? '';
    if (pin.isEmpty) {
      pin = _newPin();
      await saveSettings({'campin': pin});
    }
    final ip = await localIp() ?? '';
    if (mounted) {
      setState(() {
        _pin = pin;
        _ip = ip;
      });
    }
  }

  Future<void> _scan() async {
    final v = await Navigator.push<String>(
        context, MaterialPageRoute(builder: (_) => const QrScanPage()));
    if (v == null || !mounted) return;
    final p = v.split('|');
    if (p.length < 4) return;
    await saveSettings({'setupDone': true});
    if (!mounted) return;
    Navigator.pushReplacement(
        context,
        MaterialPageRoute(
            builder: (_) => ViewerPage(
                initialIp: p[1], initialPin: p[3], autoConnect: true)));
  }

  Widget _ok(bool v, String t, VoidCallback? fix, String label) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(v ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
            color: v ? kGreen : Colors.white38),
        title: Text(t),
        trailing: v
            ? null
            : FilledButton.tonal(onPressed: fix, child: Text(label)),
      );

  Widget _page() {
    switch (_steps[_step]) {
      case 'role':
        return Column(children: [
          const Text('ما دور هذا الهاتف؟',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 18),
          ModeCard(
            icon: Icons.videocam_rounded,
            title: 'كاميرا',
            subtitle: 'يبقى في مكانه ويبث',
            color: kAccent,
            tint: const Color(0x2622D3EE),
            onTap: () {
              setState(() => _role = 'camera');
              _next();
            },
          ),
          const SizedBox(height: 12),
          ModeCard(
            icon: Icons.visibility_rounded,
            title: 'مشاهد',
            subtitle: 'أشاهد به الكاميرا وأتحكم',
            color: const Color(0xFFA78BFA),
            tint: const Color(0x26A78BFA),
            onTap: () {
              setState(() => _role = 'viewer');
              _next();
            },
          ),
        ]);
      case 'perm':
        return FutureBuilder<List<PermissionStatus>>(
          future: Future.wait([Permission.camera.status, Permission.microphone.status]),
          builder: (ctx, snap) {
            final cam = snap.data?[0].isGranted ?? false;
            final mic = snap.data?[1].isGranted ?? false;
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('الأذونات',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              _ok(cam, 'الكاميرا', () async {
                await Permission.camera.request();
                setState(() {});
              }, 'السماح'),
              _ok(mic, 'الميكروفون', () async {
                await Permission.microphone.request();
                setState(() {});
              }, 'السماح'),
            ]);
          },
        );
      case 'bg':
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('العمل في الخلفية',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          const Text('كي تبقى الكاميرا تعمل وتُوقَظ وهي مغلقة',
              style: TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 10),
          _ok(_st['battery'] == true, 'استثناء توفير البطارية', () async {
            try {
              await _svc.invokeMethod('battery');
            } catch (_) {}
            Future.delayed(const Duration(seconds: 2), _refresh);
          }, 'استثناء'),
          _ok(_st['overlay'] == true, 'الظهور فوق التطبيقات', () async {
            try {
              await _svc.invokeMethod('overlay');
            } catch (_) {}
            Future.delayed(const Duration(seconds: 2), _refresh);
          }, 'السماح'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.touch_app_rounded, color: Colors.white54),
            title: const Text('التحكم في الشاشة (اختياري)'),
            subtitle: const Text(
                'أولاً: الإعدادات ← التطبيقات ← LAN Cam ← ⋮ ← السماح بالإعدادات المقيّدة',
                style: TextStyle(fontSize: 11, color: Colors.white54)),
            trailing: FilledButton.tonal(
                onPressed: () async {
                  try {
                    await _svc.invokeMethod('openAccessibility');
                  } catch (_) {}
                },
                child: const Text('فتح')),
          ),
        ]);
      case 'alerts':
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('إشعارات وأنت بعيد (اختياري)',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          const Text(
              'تصلك لقطة وتنبيه على هاتفك عبر تيليغرام أو ntfy حتى والتطبيق مغلق. يلزم إنترنت على هاتف الكاميرا فقط.',
              style: TextStyle(color: Colors.white60, height: 1.6)),
          const SizedBox(height: 14),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.notifications_active_rounded),
            label: const Text('إعداد الإشعارات'),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SettingsPage())),
          ),
        ]);
      default: // pair
        if (_role == 'camera') {
          return Column(children: [
            const Text('اربط جهاز المشاهدة',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            if (_ip.isEmpty || _pin.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('تأكد أنك متصل بالواي فاي'),
              )
            else ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: QrImageView(
                    data: 'LANCAM|$_ip|$kPort|$_pin',
                    version: QrVersions.auto,
                    size: 220,
                    backgroundColor: Colors.white),
              ),
              const SizedBox(height: 10),
              Text('$_ip  •  PIN $_pin',
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(color: Colors.white60)),
              const SizedBox(height: 8),
              const Text('على هاتف المشاهد: اختر "مشاهد" ثم امسح هذا الرمز.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
            ],
          ]);
        }
        return Column(children: [
          const Text('اربط الكاميرا',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          const Text('على هاتف الكاميرا افتح "وضع الكاميرا" ثم "عرض رمز QR للربط"، وامسحه هنا.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white60, height: 1.6)),
          const SizedBox(height: 18),
          FilledButton.icon(
            icon: const Icon(Icons.qr_code_scanner_rounded),
            label: const Text('مسح الرمز'),
            onPressed: _scan,
          ),
        ]);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('الإعداد السريع'),
          actions: [
            TextButton(onPressed: _finish, child: const Text('تخطي')),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(children: [
              if (_role.isNotEmpty)
                LinearProgressIndicator(value: (_step + 1) / _steps.length),
              const SizedBox(height: 18),
              Expanded(child: SingleChildScrollView(child: _page())),
              if (_steps[_step] != 'role')
                Row(children: [
                  if (_step > 0)
                    TextButton(
                        onPressed: () => setState(() => _step--),
                        child: const Text('السابق')),
                  const Spacer(),
                  FilledButton(
                    onPressed: _next,
                    child: Text(_step + 1 >= _steps.length ? 'تم' : 'التالي'),
                  ),
                ]),
            ]),
          ),
        ),
      );
}


class _DotPainter extends CustomPainter {
  _DotPainter(this.p);
  final Offset p;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawCircle(p, 22, Paint()..color = const Color(0x33FFFFFF));
    canvas.drawCircle(
        p,
        22,
        Paint()
          ..color = const Color(0x88FFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_DotPainter old) => old.p != p;
}

class _Gray {
  _Gray(this.g, this.w, this.h);
  final Uint8List g;
  final int w;
  final int h;
}

/// A motion snapshot received by the viewer.
class _Evt {
  _Evt(this.t, this.img, [this.kind = 'motion']);
  final DateTime t;
  final Uint8List img;
  final String kind; // motion | sound
  Uint8List? img2; // snapshot 3 s later (before / after comparison)
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
    this.leading,
  });
  final Widget? leading;
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
              leading ??
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
    initShortcuts();
    _firstRun();
  }

  Future<void> _firstRun() async {
    final st = await loadSettings();
    if (st['setupDone'] == true || !mounted) return;
    if (st['campin'] != null || st['ip'] != null) {
      saveSettings({'setupDone': true}); // existing user: no wizard
      return;
    }
    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted || CameraPage.active) return;
    Navigator.push(
        context, MaterialPageRoute(builder: (_) => const SetupWizard()));
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
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: kUiRev,
        builder: (_, __, ___) => kSimple ? _simpleHome() : _advancedHome(),
      );

  Widget _big(IconData icon, String title, String sub, Color col,
          VoidCallback onTap) =>
      Expanded(
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 14),
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: kSurface,
              borderRadius: BorderRadius.circular(26),
              border: Border.all(color: col.withAlpha(128), width: 2),
            ),
            child: Row(children: [
              Container(
                width: 74,
                height: 74,
                decoration: BoxDecoration(
                    color: col.withAlpha(46), shape: BoxShape.circle),
                child: Icon(icon, size: 42, color: col),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 28, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      Text(sub,
                          style: const TextStyle(
                              fontSize: 15, color: Colors.white60)),
                    ]),
              ),
            ]),
          ),
        ),
      );

  Future<void> _simpleWatch() async {
    final st = await loadSettings();
    final l = st['cams'];
    if (!mounted) return;
    if (l is List && l.length > 1) {
      Navigator.push(context,
          MaterialPageRoute(builder: (_) => const MultiViewPage()));
    } else if (l is List && l.length == 1) {
      final c = Map<String, dynamic>.from(l[0] as Map);
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ViewerPage(
                  initialIp: '${c['ip']}',
                  initialPin: '${c['pin']}',
                  autoConnect: true)));
    } else if ('${st['ip'] ?? ''}'.isNotEmpty) {
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ViewerPage(
                  initialIp: '${st['ip']}',
                  initialPin: '${st['pin'] ?? ''}',
                  autoConnect: true)));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('لا توجد كاميرا محفوظة — أضف واحدة أولاً')));
    }
  }

  Future<void> _simpleAdd() async {
    final cam = await addCamFromQr(context);
    if (cam == null || !mounted) return;
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => ViewerPage(
                initialIp: '${cam['ip']}',
                initialPin: '${cam['pin']}',
                autoConnect: true)));
  }

  Widget _simpleHome() => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 8),
            child: Column(children: [
              const LogoMark(size: 64),
              const SizedBox(height: 6),
              const Text('LAN Cam',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 14),
              _big(Icons.visibility_rounded, 'شاهد', 'افتح الكاميرا الآن',
                  kAccent, _simpleWatch),
              _big(Icons.add_a_photo_rounded, 'أضف كاميرا',
                  'امسح رمز QR من الكاميرا', kGreen, _simpleAdd),
              _big(
                  Icons.help_outline_rounded,
                  'ساعدني',
                  'حل المشاكل وشرح الاستخدام',
                  const Color(0xFFFBBF24),
                  () => Navigator.push(context,
                      MaterialPageRoute(builder: (_) => const HelpHubPage()))),
              TextButton(
                onPressed: () {
                  saveSettings({'simple': false}).then((_) async {
                    applyUiPrefs(await loadSettings());
                  });
                },
                child: const Text('الوضع المتقدم'),
              ),
            ]),
          ),
        ),
      );

  Widget _advancedHome() => Scaffold(
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
                      leading: const ThumbPreview(
                          multi: false,
                          icon: Icons.visibility_rounded,
                          color: Color(0xFFA78BFA),
                          tint: Color(0x26A78BFA)),
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
                      leading: const ThumbPreview(
                          multi: true,
                          icon: Icons.grid_view_rounded,
                          color: Color(0xFFF472B6),
                          tint: Color(0x26F472B6)),
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
                    const SizedBox(height: 12),
                    Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                      TextButton.icon(
                        icon: const Icon(Icons.health_and_safety_rounded, size: 18),
                        label: const Text('لماذا لا يعمل؟'),
                        onPressed: () => Navigator.push(context,
                            MaterialPageRoute(builder: (_) => const DiagPage())),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.rocket_launch_rounded, size: 18),
                        label: const Text('الإعداد السريع'),
                        onPressed: () => Navigator.push(context,
                            MaterialPageRoute(builder: (_) => const SetupWizard())),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.help_outline_rounded, size: 18),
                        label: const Text('ساعدني'),
                        onPressed: () => Navigator.push(context,
                            MaterialPageRoute(builder: (_) => const HelpHubPage())),
                      ),
                    ]),
                    const SizedBox(height: 16),
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
    applyUiPrefs(_s);
  }

  Widget _field(String label, String key,
          {bool obscure = false, String hint = ''}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          key: ValueKey('f_${key}_${_s[key] ?? ''}'),
          initialValue: '${_s[key] ?? ''}',
          obscureText: obscure,
          textDirection: TextDirection.ltr,
          onChanged: (v) {
            _s[key] = v.trim();
            saveSettings({key: v.trim()});
          },
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            filled: true,
            fillColor: kBg,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none),
          ),
        ),
      );

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
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
          _group('الواجهة وإمكانية الوصول', Icons.accessibility_new_rounded, [
            _chips<bool>('واجهة مبسّطة (3 أزرار)', 'simple', false,
                [false, true], ['إيقاف', 'تشغيل']),
            _chips<String>('اللغة', 'lang', 'auto',
                ['auto', 'ar', 'en', 'fr', 'tr', 'ur'],
                ['تلقائي', 'العربية', 'English', 'Français', 'Türkçe', 'اردو']),
            _chips<double>('حجم الخط', 'fontScale', 1.0, [1.0, 1.25, 1.5],
                ['عادي', 'كبير', 'كبير جداً']),
            _chips<bool>('تباين عالٍ', 'contrast', false, [false, true],
                ['إيقاف', 'تشغيل']),
            _chips<bool>('قراءة التنبيهات بصوت عالٍ', 'speak', false,
                [false, true], ['إيقاف', 'تشغيل']),
          ]),
          _group('قفل التطبيق', Icons.lock_rounded, [
            _chips<bool>('قفل التطبيق (بصمة / وجه / رمز)', 'appLock', false,
                [false, true], ['إيقاف', 'تشغيل']),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.pin_rounded),
              title: const Text('تعيين رمز القفل'),
              subtitle: const Text('رمز من 4 إلى 6 أرقام',
                  style: TextStyle(fontSize: 11, color: Colors.white54)),
              onTap: () async {
                final ctl = TextEditingController();
                final v = await showDialog<String>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: kSurface,
                    title: const Text('تعيين رمز القفل'),
                    content: TextField(
                      controller: ctl,
                      keyboardType: TextInputType.number,
                      obscureText: true,
                      maxLength: 6,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('إلغاء')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, ctl.text),
                          child: const Text('حفظ')),
                    ],
                  ),
                );
                if (v != null && v.length >= 4) {
                  _set('appLockPin', v);
                } else if (v != null) {
                  _toast('رمز من 4 إلى 6 أرقام');
                }
              },
            ),
          ]),
          _group('أتمتة (اختصارات iOS)', Icons.bolt_rounded, [
            _chips<bool>('تفعيل رابط الأتمتة (المنفذ 8082، غير مشفّر)', 'autoSrv',
                false, [false, true], ['إيقاف', 'تشغيل']),
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                  'مثال: في تطبيق "اختصارات" أنشئ أتمتة "عند الاتصال بشبكة الواي فاي" تُنفّذ "الحصول على محتويات URL":\nhttp://عنوان-الكاميرا:8082/mode?pin=الرمز&home=1\nوأخرى عند المغادرة بـ home=0. يُوقف الكشف أثناء وجودك بالمنزل.',
                  textDirection: TextDirection.ltr,
                  style: TextStyle(fontSize: 11, color: Colors.white60, height: 1.6)),
            ),
          ]),
          _group('إشعارات خارجية (والتطبيق مغلق)', Icons.send_rounded, [
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                  'تُعدّ على هاتف الكاميرا. تيليغرام: أنشئ بوتاً من @BotFather وضع الرمز، ثم أرسل أي رسالة للبوت واضغط "جلب Chat ID". ntfy: ثبّت تطبيق ntfy على هاتفك واشترك بنفس اسم الموضوع. يلزم إنترنت على هاتف الكاميرا.',
                  style: TextStyle(fontSize: 12, color: Colors.white60, height: 1.6)),
            ),
            _field('Telegram Bot Token', 'tgToken', obscure: true),
            _field('Telegram Chat ID', 'tgChat'),
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Wrap(spacing: 8, children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.search_rounded, size: 18),
                  label: const Text('جلب Chat ID'),
                  onPressed: () async {
                    final id = await tgFindChat('${_s['tgToken'] ?? ''}'.trim());
                    if (id == null) {
                      _toast('لم أجد رسالة: أرسل رسالة للبوت أولاً وتأكد من الرمز');
                    } else {
                      setState(() => _s['tgChat'] = id);
                      saveSettings({'tgChat': id});
                      _toast('تم جلب Chat ID');
                    }
                  },
                ),
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.outbox_rounded, size: 18),
                  label: const Text('إرسال اختبار'),
                  onPressed: () async {
                    final r = await sendPush('LAN Cam', 'رسالة تجريبية');
                    _toast(r == null
                        ? 'لم تُضبط أي قناة بعد'
                        : (r ? 'وصلت الرسالة' : 'فشل الإرسال: تحقق من البيانات والإنترنت'));
                  },
                ),
              ]),
            ),
            _field('ntfy topic', 'ntfyTopic', hint: 'مثال: lancam-ahmed-8f3k'),
            _field('خادم ntfy (اختياري)', 'ntfyUrl', hint: 'https://ntfy.sh'),
            _chips<int>('ملخص يومي بإشعار', 'dailyHour', -1,
                [-1, 20, 21, 22, 23], ['إيقاف', '8 م', '9 م', '10 م', '11 م']),
          ]),
          _group('نسخ احتياطي', Icons.cloud_upload_rounded, [
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text(
                  'WebDAV (Nextcloud أو NAS): كل تسجيل ينتهي يُرفع تلقائياً من هاتف الكاميرا. النسخ إلى الصور على الـ iPhone يتم عند الاتصال بالكاميرا.',
                  style: TextStyle(fontSize: 12, color: Colors.white60, height: 1.6)),
            ),
            _field('رابط WebDAV (جهاز الكاميرا)', 'wdUrl',
                hint: 'https://server/remote.php/dav/files/user/LANCam'),
            _field('اسم المستخدم', 'wdUser'),
            _field('كلمة المرور', 'wdPass', obscure: true),
            _chips<bool>('نسخ التسجيلات إلى الصور تلقائياً (جهاز المشاهدة)',
                'autoBackup', false, [false, true], ['إيقاف', 'تشغيل']),
          ]),
          _group('مساعدة', Icons.help_outline_rounded, [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.rocket_launch_rounded),
              title: const Text('الإعداد السريع'),
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const SetupWizard())),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.health_and_safety_rounded),
              title: const Text('لماذا لا يعمل؟'),
              onTap: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const DiagPage())),
            ),
          ]),
          _group('التنبيهات (جهاز المشاهدة)', Icons.notifications_active_rounded, [
            _chips<int>('تنبيه بطارية الكاميرا عند', 'alertBat', 20,
                [15, 20, 30], ['15%', '20%', '30%']),
            _chips<int>('تنبيه حرارة الكاميرا عند', 'alertTemp', 45,
                [42, 45, 48], ['42°', '45°', '48°']),
            _chips<bool>('صوت التنبيه', 'alertSound', true, [true, false],
                ['تشغيل', 'إيقاف']),
            _chips<bool>('اهتزاز التنبيه', 'alertHaptic', true, [true, false],
                ['تشغيل', 'إيقاف']),
            _chips<int>('أقل فاصل بين تنبيهات الحركة والصوت', 'alertGap', 20,
                [10, 20, 60], ['10 ث', '20 ث', 'دقيقة']),
          ]),
          _group('المشاهدة', Icons.visibility_rounded, [
            _chips<bool>('إعادة الاتصال التلقائية', 'autoRetry', true,
                [true, false], ['مفعّلة', 'معطّلة']),
            _chips<bool>('كتم الصوت عند الاتصال', 'muteStart', false,
                [false, true], ['لا', 'نعم']),
            _chips<bool>('إبقاء الشاشة مضاءة', 'keepOn', true, [true, false],
                ['نعم', 'لا']),
          ]),
          _group('الأمان', Icons.lock_rounded, [
            _chips<int>('محاولات PIN الخاطئة قبل القفل', 'lockTries', 5,
                [3, 5, 10], ['3', '5', '10']),
            _chips<int>('مدة القفل', 'lockMin', 5, [1, 5, 15],
                ['دقيقة', '5 دقائق', '15 دقيقة']),
            _chips<bool>('PIN جديد عند كل تشغيل للكاميرا', 'pinRotate', false,
                [false, true], ['لا', 'نعم']),
            Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: kBg,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                  kTls
                      ? 'تشفير TLS: مفعّل في هذا الإصدار (يشمل البث والـ PIN والمكتبة). إيقاظ الكاميرا (المنفذ 8081) ما زال غير مشفّر.'
                      : 'تشفير TLS: غير مضمّن في هذا الإصدار.',
                  style: TextStyle(
                      fontSize: 12, color: kTls ? kGreen : Colors.amber)),
            ),
          ]),
          _group('متقدم', Icons.build_rounded, [
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.copy_rounded),
              title: const Text('نسخ معلومات التشخيص'),
              subtitle: const Text('تُنسخ بدون الـ PIN، للصقها عند طلب المساعدة',
                  style: TextStyle(fontSize: 11, color: Colors.white54)),
              onTap: () async {
                final c = Map<String, dynamic>.from(_s)
                  ..remove('pin')
                  ..remove('campin')
                  ..remove('cams');
                final txt = 'LAN Cam | ${Platform.operatingSystem} '
                    '${Platform.operatingSystemVersion}\n'
                    'TLS: $kTls | Person: $kPersonSupported\n'
                    '${jsonEncode(c)}';
                await Clipboard.setData(ClipboardData(text: txt));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('تم النسخ')));
                }
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.restart_alt_rounded),
              title: const Text('إعادة ضبط كل الإعدادات'),
              subtitle: const Text('تُحذف الإعدادات والكاميرات المحفوظة',
                  style: TextStyle(fontSize: 11, color: Colors.white54)),
              onTap: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: kSurface,
                    title: const Text('إعادة ضبط كل شيء؟'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('إلغاء')),
                      FilledButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          child: const Text('إعادة ضبط')),
                    ],
                  ),
                );
                if (ok != true) return;
                try {
                  await (await _settingsFile()).writeAsString('{}');
                } catch (_) {}
                if (mounted) setState(() => _s = {});
              },
            ),
          ]),
          _group('مشاركة الشاشة والتحكم', Icons.phone_android_rounded, [
            _chips<int>('الإطارات في الثانية (الحد الأعلى)', 'sfps', 60,
                [30, 60, 90, 120], ['30', '60', '90', '120']),
            _chips<int>('جودة الصورة', 'squality', 50, [30, 50, 70, 85],
                ['سريعة جداً', 'سريعة', 'متوازنة', 'عالية']),
            _chips<int>('الدقة', 'sside', 960, [720, 960, 1280, 1920],
                ['720', '960', '1280', '1920']),
            const Padding(
              padding: EdgeInsets.only(bottom: 14),
              child: Text(
                  'الإطارات الفعلية تعتمد على سرعة هاتف Android في ضغط الصور وعلى الواي فاي. للحصول على أعلى معدل اختر دقة وجودة أقل.',
                  style: TextStyle(fontSize: 11, color: Colors.white54)),
            ),
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
  // motion detection / zones / loop recording
  Timer? _motionTimer;
  Timer? _loopTimer;
  bool _mOn = false;
  bool _mRec = false;
  int _mSens = 1;
  bool _mFilter = true;
  String _mZMode = 'ignore';
  String _mZMask = '0' * 48;
  int _mLoop = 0; // MB, 0 = off
  Uint8List? _prevG;
  int _gw = 0;
  int _gh = 0;
  int _streak = 0;
  bool _motionBusy = false;
  bool _motionNow = false;
  bool _autoRec = false;
  String? _recPath;
  DateTime _lastMotion = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastAlert = DateTime.fromMillisecondsSinceEpoch(0);
  // sound detection / schedule / power saving / siren
  bool _sOn = false;
  bool _sched = false;
  int _sSh = 22;
  int _sEh = 6;
  bool _idleDim = false;
  bool _dim = false;
  DateTime? _idleSince;
  RTCPeerConnection? _probeA;
  RTCPeerConnection? _probeB;
  Timer? _soundTimer;
  Timer? _sirenTimer;
  double _ambient = 0.02;
  int _loudStreak = 0;
  int _noLevel = 0;
  bool? _soundOk;
  DateTime _lastSound = DateTime.fromMillisecondsSinceEpoch(0);
  // pre-motion recording / person check / security limits
  bool _pre = false;
  bool _rolling = false;
  bool _preBusy = false;
  DateTime _rollStart = DateTime.now();
  Timer? _preTimer;
  bool _mPerson = false;
  int _lockTries = 5;
  int _lockMin = 5;
  int _alertGap = 20;
  bool get _recShown => _recording && !_rolling;
  bool _dropping = false;
  int _homeUntil = 0; // 0 off, -1 until switched off, else expiry (ms)
  HttpServer? _autoSrv;
  final List<Map<String, dynamic>> _log = [];
  int _care = 0;
  DateTime _careBase = DateTime.now();
  bool _careAlerted = false;
  double _lastLvl = 0;
  DateTime _lastLvlSent = DateTime.fromMillisecondsSinceEpoch(0);
  bool get _homeActive =>
      _homeUntil == -1 ||
      (_homeUntil > 0 && DateTime.now().millisecondsSinceEpoch < _homeUntil);
  // view-only PIN, charge start, notifications, time-lapse
  String _viewPin = '';
  bool _chargeStart = false;
  bool _lastChg = false;
  bool _lowSent = false;
  int _lastTickMs = DateTime.now().millisecondsSinceEpoch;
  int _tl = 0;
  DateTime _lastTl = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _tlTimer;
  Timer? _pushTimer;
  int _lastSummaryDay = 0;
  int _dailyHour = -1;
  int _aliveSave = 0;
  final Set<String> _wdPending = {};

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
    _pin = (s['pinRotate'] == true)
        ? _newPin()
        : ((s['campin'] as String?) ?? _newPin());
    await saveSettings({'campin': _pin});
    _always = (s['always'] as bool?) ?? false;
    _range = (s['range'] as bool?) ?? false;
    _clockOn = (s['clock'] as bool?) ?? true;
    _level = _range ? 3 : 0;
    _mOn = (s['m_on'] as bool?) ?? false;
    _mRec = (s['m_rec'] as bool?) ?? false;
    _mSens = ((s['m_sens'] as int?) ?? 1).clamp(0, 2).toInt();
    _mFilter = (s['m_filter'] as bool?) ?? true;
    _mZMode = (s['m_zmode'] as String?) ?? 'ignore';
    final zm = (s['m_zmask'] as String?) ?? '';
    if (zm.length == 48) _mZMask = zm;
    _mLoop = (s['m_loop'] as int?) ?? 0;
    _sOn = (s['m_son'] as bool?) ?? false;
    _sched = (s['m_sched'] as bool?) ?? false;
    _sSh = (s['m_sh'] as int?) ?? 22;
    _sEh = (s['m_eh'] as int?) ?? 6;
    _idleDim = (s['idle_dim'] as bool?) ?? false;
    _pre = (s['m_pre'] as bool?) ?? false;
    _mPerson = (s['m_person'] as bool?) ?? false;
    _lockTries = (s['lockTries'] as int?) ?? 5;
    _lockMin = (s['lockMin'] as int?) ?? 5;
    _alertGap = (s['alertGap'] as int?) ?? 20;
    _chargeStart = s['chargeStart'] == true;
    _homeUntil = (s['m_home'] as int?) ?? 0;
    _care = (s['m_care'] as int?) ?? 0;
    _careBase = DateTime.now();
    _tl = (s['m_tl'] as int?) ?? 0;
    _dailyHour = (s['dailyHour'] as int?) ?? -1;
    _viewPin = (s['viewpin'] as String?) ?? '';
    if (_viewPin.isEmpty || _viewPin == _pin) {
      _viewPin = _newPin();
      saveSettings({'viewpin': _viewPin});
    }
    final aliveTs = (s['aliveTs'] as int?) ?? 0;
    if (aliveTs > 0) {
      final gap = DateTime.now().millisecondsSinceEpoch - aliveTs;
      if (gap > 180000 && gap < 43200000) {
        PushQueue.send('LAN Cam',
            'عادت الكاميرا للعمل بعد ${gap ~/ 60000} دقيقة من التوقف');
      }
    }
    await applyNetConfig();
    if (Platform.isAndroid) {
      try {
        await _svc.invokeMethod(
            'config', {'always': _always, 'pin': _pin, 'charge': _chargeStart});
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

    final tctx = tlsServerContext();
    _server = tctx != null
        ? await HttpServer.bindSecure(InternetAddress.anyIPv4, kPort, tctx)
        : await HttpServer.bind(InternetAddress.anyIPv4, kPort);
    _server!.listen((req) async {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        await _http(req);
        return;
      }
      final remote = req.connectionInfo?.remoteAddress.address ?? '?';
      final ws = await WebSocketTransformer.upgrade(req);
      var authed = false;
      var role = 'admin';
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
            final rl = _roleFor('${d['pin'] ?? ''}');
            if (rl == null) {
              _fails.putIfAbsent(remote, () => []).add(DateTime.now());
              ws.add(jsonEncode({'type': 'denied'}));
              await ws.close();
              return;
            }
            _fails.remove(remote);
            authed = true;
            role = rl;
            _logAccess(remote, rl, 'live');
            _ws = ws;
            ws.add(jsonEncode({'type': 'role', 'role': rl}));
            await _answer(ws, d['sdp'] as String);
            _sendRec();
            _sendCfg();
            break;
          case 'record':
            if (authed && role == 'admin') await _setRec(d['on'] == true);
            break;
          case 'cmd':
            if (authed && role == 'admin') await _cmd(d);
            break;
          case 'screen':
            if (_locked(remote)) {
              ws.add(jsonEncode({'type': 'locked'}));
              await ws.close();
              return;
            }
            final rl = _roleFor('${d['pin'] ?? ''}');
            if (rl == null) {
              _fails.putIfAbsent(remote, () => []).add(DateTime.now());
              ws.add(jsonEncode({'type': 'denied'}));
              await ws.close();
              return;
            }
            _fails.remove(remote);
            authed = true;
            role = rl;
            _logAccess(remote, rl, 'screen');
            ws.add(jsonEncode({'type': 'role', 'role': rl}));
            await _attachScreen(ws);
            break;
          case 'tap':
          case 'swipe':
          case 'nav':
          case 'touch':
            if (authed && role == 'admin') await _remoteInput(d);
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
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _now.value = DateTime.now();
      _idleTick();
      final ms = DateTime.now().millisecondsSinceEpoch;
      if (ms - _lastTickMs > 180000) {
        PushQueue.send('LAN Cam',
            'الكاميرا كانت متوقفة ${(ms - _lastTickMs) ~/ 60000} دقيقة وعادت الآن');
      }
      _lastTickMs = ms;
      _dailyCheck();
    });
    _pushTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      PushQueue.flush();
      _wdFlush();
      _careCheck();
      if (++_aliveSave % 2 == 0) {
        saveSettings({'aliveTs': DateTime.now().millisecondsSinceEpoch});
      }
    });
    _tlTimer = Timer.periodic(const Duration(seconds: 20), (_) => _tlTick());
    if (s['autoSrv'] == true) _startAutoServer();
    _loadLog();
    _soundTimer =
        Timer.periodic(const Duration(milliseconds: 500), (_) => _soundTick());
    _preTimer = Timer.periodic(const Duration(seconds: 1), (_) => _preTick());
    _motionTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _motionTick());
    _loopTimer =
        Timer.periodic(const Duration(seconds: 60), (_) => _enforceLoop());
    _enforceLoop();
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

  String? _roleFor(String p) => p == _pin
      ? 'admin'
      : ((_viewPin.isNotEmpty && p == _viewPin) ? 'view' : null);

  bool _locked(String ip) {
    final l = _fails[ip];
    if (l == null) return false;
    l.removeWhere(
        (t) => DateTime.now().difference(t) > Duration(minutes: _lockMin));
    return l.length >= _lockTries;
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
      final bat = m['bat'];
      final chg = m['chg'] == true;
      if (bat is int) {
        if (chg) _lowSent = false;
        if (!chg && bat <= 15 && !_lowSent) {
          _lowSent = true;
          PushQueue.send('بطارية الكاميرا منخفضة', '$bat% — وصّلها بالشاحن');
        }
        if (_lastChg && !chg) {
          PushQueue.send('فُصل الشاحن', 'بطارية الكاميرا $bat%');
        }
        _lastChg = chg;
      }
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

  // ───────────── motion detection ─────────────
  void _sendCfg() {
    try {
      _ws?.add(jsonEncode({
        'type': 'cfg',
        'on': _mOn,
        'rec': _mRec,
        'sens': _mSens,
        'filter': _mFilter,
        'zmode': _mZMode,
        'zmask': _mZMask,
        'loop': _mLoop,
        'android': Platform.isAndroid,
        'son': _sOn,
        'sound': _soundOk,
        'sched': _sched,
        'sh': _sSh,
        'eh': _sEh,
        'pre': _pre,
        'tl': _tl,
        'home': _homeCode(),
        'care': _care,
        'person': _mPerson,
        'personAvail': kPersonSupported,
      }));
    } catch (_) {}
  }

  void _applyCfg(Map d) {
    if (d['on'] is bool) _mOn = d['on'] as bool;
    if (d['rec'] is bool) _mRec = d['rec'] as bool;
    if (d['sens'] is num) {
      _mSens = (d['sens'] as num).toInt().clamp(0, 2).toInt();
    }
    if (d['filter'] is bool) _mFilter = d['filter'] as bool;
    if (d['zmode'] == 'ignore' || d['zmode'] == 'only') {
      _mZMode = d['zmode'] as String;
    }
    if (d['zmask'] is String && (d['zmask'] as String).length == 48) {
      _mZMask = d['zmask'] as String;
    }
    if (d['loop'] is num) {
      _mLoop = (d['loop'] as num).toInt().clamp(0, 102400).toInt();
    }
    if (d['son'] is bool) {
      _sOn = d['son'] as bool;
      if (!_sOn) _closeProbe();
    }
    if (d['sched'] is bool) _sched = d['sched'] as bool;
    if (d['pre'] is bool) _pre = d['pre'] as bool;
    if (d['home'] is num) {
      final h = (d['home'] as num).toInt();
      _homeUntil = h == 0
          ? 0
          : (h < 0
              ? -1
              : DateTime.now().millisecondsSinceEpoch + h * 3600000);
    }
    if (d['care'] is num) {
      _care = (d['care'] as num).toInt().clamp(0, 48).toInt();
      _careBase = DateTime.now();
      _careAlerted = false;
    }
    if (d['tl'] is num) _tl = (d['tl'] as num).toInt().clamp(0, 60).toInt();
    if (d['person'] is bool) _mPerson = d['person'] as bool;
    if (d['sh'] is num) _sSh = (d['sh'] as num).toInt().clamp(0, 23).toInt();
    if (d['eh'] is num) _sEh = (d['eh'] as num).toInt().clamp(0, 23).toInt();
    if (d['idle'] is bool) {
      _idleDim = d['idle'] as bool;
      saveSettings({'idle_dim': _idleDim});
    }
    _prevG = null;
    _streak = 0;
    saveSettings({
      'm_pre': _pre,
      'm_home': _homeUntil,
      'm_care': _care,
      'm_tl': _tl,
      'm_person': _mPerson,
      'm_son': _sOn,
      'm_sched': _sched,
      'm_sh': _sSh,
      'm_eh': _sEh,
      'm_on': _mOn,
      'm_rec': _mRec,
      'm_sens': _mSens,
      'm_filter': _mFilter,
      'm_zmode': _mZMode,
      'm_zmask': _mZMask,
      'm_loop': _mLoop,
    });
    _sendCfg();
    _enforceLoop();
    if (mounted) setState(() {});
  }

  Future<_Gray?> _gray(Uint8List png, int tw) async {
    ui.Codec? codec;
    ui.Image? img;
    try {
      codec = await ui.instantiateImageCodec(png, targetWidth: tw);
      img = (await codec.getNextFrame()).image;
      final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (bd == null) return null;
      final w = img.width;
      final h = img.height;
      final px = bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
      final g = Uint8List(w * h);
      for (var i = 0, j = 0; i < w * h; i++, j += 4) {
        g[i] = (px[j] * 30 + px[j + 1] * 59 + px[j + 2] * 11) ~/ 100;
      }
      return _Gray(g, w, h);
    } catch (_) {
      return null;
    } finally {
      img?.dispose();
      codec?.dispose();
    }
  }

  Future<Uint8List?> _thumb(Uint8List png, [int w = 480]) async {
    ui.Codec? codec;
    ui.Image? img;
    try {
      codec = await ui.instantiateImageCodec(png, targetWidth: w);
      img = (await codec.getNextFrame()).image;
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      if (bd == null) return null;
      return bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
    } catch (_) {
      return null;
    } finally {
      img?.dispose();
      codec?.dispose();
    }
  }

  /// [changed fraction, largest blob (cells)] between two gray frames,
  /// after removing global brightness change and applying the zones.
  List<double> _analyze(Uint8List a, Uint8List b, int w, int h) {
    var sa = 0;
    var sb = 0;
    for (var i = 0; i < a.length; i++) {
      sa += a[i];
      sb += b[i];
    }
    final off = (sb - sa) ~/ a.length;
    final thr = const [30, 20, 12][_mSens];
    final ch = Uint8List(w * h);
    var counted = 0;
    var changed = 0;
    final hasMask = _mZMask.length == 48;
    for (var y = 0; y < h; y++) {
      final cy = y * 6 ~/ h;
      for (var x = 0; x < w; x++) {
        final cx = x * 8 ~/ w;
        final inZ = hasMask && _mZMask[cy * 8 + cx] == '1';
        if (_mZMode == 'ignore' ? inZ : !inZ) continue;
        counted++;
        final i = y * w + x;
        if (((b[i] - a[i]) - off).abs() > thr) {
          ch[i] = 1;
          changed++;
        }
      }
    }
    if (counted == 0) return [0, 0];
    var best = 0;
    if (changed > 0) {
      final seen = Uint8List(w * h);
      final st = <int>[];
      for (var s0 = 0; s0 < ch.length; s0++) {
        if (ch[s0] == 0 || seen[s0] == 1) continue;
        var size = 0;
        st.add(s0);
        seen[s0] = 1;
        while (st.isNotEmpty) {
          final p = st.removeLast();
          size++;
          final x = p % w;
          final y = p ~/ w;
          if (x > 0 && ch[p - 1] == 1 && seen[p - 1] == 0) {
            seen[p - 1] = 1;
            st.add(p - 1);
          }
          if (x < w - 1 && ch[p + 1] == 1 && seen[p + 1] == 0) {
            seen[p + 1] = 1;
            st.add(p + 1);
          }
          if (y > 0 && ch[p - w] == 1 && seen[p - w] == 0) {
            seen[p - w] = 1;
            st.add(p - w);
          }
          if (y < h - 1 && ch[p + w] == 1 && seen[p + w] == 0) {
            seen[p + w] = 1;
            st.add(p + w);
          }
        }
        if (size > best) best = size;
      }
    }
    return [changed / counted, best.toDouble()];
  }

  Future<void> _motionTick() async {
    final now = DateTime.now();
    if (_autoRec && !_recording) _autoRec = false;
    // auto-recording ends 15 s after the last movement
    if (_autoRec && _recording && now.difference(_lastMotion).inSeconds > 15) {
      _autoRec = false;
      await _toggleRec();
      _sendRec();
    }
    if (_motionNow && now.difference(_lastMotion).inSeconds >= 3) {
      if (mounted) setState(() => _motionNow = false);
    }
    if (!_mOn || !_inSchedule() || _motionBusy || _stream == null) return;
    final tracks = _stream!.getVideoTracks();
    if (tracks.isEmpty) return;
    _motionBusy = true;
    try {
      final buf = await tracks.first.captureFrame();
      final png = buf.asUint8List();
      final cur = await _gray(png, 64);
      if (cur == null) return;
      final prev = _prevG;
      _prevG = cur.g;
      if (prev == null || _gw != cur.w || _gh != cur.h) {
        _gw = cur.w;
        _gh = cur.h;
        return;
      }
      final r = _analyze(prev, cur.g, cur.w, cur.h);
      final frac = r[0];
      final blob = r[1];
      final minFrac = const [0.04, 0.02, 0.01][_mSens];
      bool hit;
      if (frac > 0.6) {
        hit = false; // lights switched / camera moved
      } else if (_mFilter) {
        hit = frac >= minFrac && blob >= max(10.0, cur.w * cur.h * 0.008);
      } else {
        hit = frac >= minFrac * 0.5;
      }
      _streak = hit ? _streak + 1 : 0;
      if (_streak < (_mFilter ? 2 : 1)) return;

      if (_mPerson && kPersonSupported) {
        // movement only counts when a person is really in the picture
        final isPerson = await detectPerson(png);
        if (!isPerson) return;
      }
      _lastMotion = now;
      if (mounted && !_motionNow) setState(() => _motionNow = true);
      await _autoRecStart();
      if (now.difference(_lastAlert).inSeconds >= _alertGap) {
        _lastAlert = now;
        await _emitEvent('motion', png, now);
      }
    } catch (_) {
    } finally {
      _motionBusy = false;
    }
  }

  /// Snapshots are kept on the camera phone too (last 50).
  Future<void> _saveEvent(Uint8List img, DateTime t, String kind,
      [String suffix = '']) async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}/events');
      if (!await dir.exists()) await dir.create(recursive: true);
      await File('${dir.path}/evt_${fmtFile(t)}_$kind$suffix.png')
          .writeAsBytes(img);
      final files = <File>[];
      await for (final e in dir.list()) {
        if (e is File) files.add(e);
      }
      if (files.length > 100) {
        files.sort((a, b) => a.path.compareTo(b.path));
        for (final f in files.take(files.length - 100)) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  /// Loop recording: delete the oldest recordings above the size limit.
  Future<void> _enforceLoop() async {
    if (_mLoop <= 0 || !Platform.isAndroid) return;
    try {
      final dir = await getExternalStorageDirectory() ??
          await getApplicationDocumentsDirectory();
      final files = <File>[];
      await for (final e in dir.list()) {
        if (e is File && RegExp(r'cam_.*\.(mp4|srt)$').hasMatch(e.path)) {
          files.add(e);
        }
      }
      final stats = <String, FileStat>{};
      var total = 0;
      for (final f in files) {
        final st = await f.stat();
        stats[f.path] = st;
        total += st.size;
      }
      final limit = _mLoop * 1024 * 1024;
      if (total <= limit) return;
      files.sort(
          (a, b) => stats[a.path]!.modified.compareTo(stats[b.path]!.modified));
      final cur = _recPath;
      final curSrt = cur?.replaceFirst(RegExp(r'\.mp4$'), '.srt');
      for (final f in files) {
        if (total <= limit * 0.9) break;
        if (_recording && (f.path == cur || f.path == curSrt)) continue;
        if (_wdPending.contains(f.path)) continue;
        total -= stats[f.path]!.size;
        try {
          await f.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  // ───────────── schedule / events / sound / siren / power saving ─────────────
  bool _inSchedule() {
    if (_homeActive) return false; // "I'm at home": detection paused
    if (!_sched) return true;
    final h = DateTime.now().hour;
    return _sSh <= _sEh ? (h >= _sSh && h < _sEh) : (h >= _sSh || h < _sEh);
  }

  Future<void> _autoRecStart() async {
    if (!_mRec || !Platform.isAndroid) return;
    if (_rolling) {
      // the pre-roll segment becomes the event recording
      _rolling = false;
      _autoRec = true;
      if (mounted) setState(() {});
      _sendRec();
      return;
    }
    if (!_recording) {
      _autoRec = true;
      await _toggleRec();
      _sendRec();
    }
  }

  /// Pre-motion recording: a rolling 10 s segment is always being recorded and
  /// thrown away; when movement is detected the running one is kept.
  Future<void> _preTick() async {
    if (_preBusy) return;
    _preBusy = true;
    try {
      final want = _pre &&
          _mRec &&
          _mOn &&
          _inSchedule() &&
          Platform.isAndroid &&
          _stream != null &&
          !_autoRec;
      if (!want) {
        if (_rolling) await _dropRolling();
        return;
      }
      if (!_recording) {
        _rolling = true;
        _rollStart = DateTime.now();
        await _toggleRec();
        return;
      }
      if (_rolling && DateTime.now().difference(_rollStart).inSeconds >= 10) {
        await _dropRolling();
        _rolling = true;
        _rollStart = DateTime.now();
        await _toggleRec();
      }
    } catch (_) {
      _rolling = false;
    } finally {
      _preBusy = false;
    }
  }

  Future<void> _dropRolling() async {
    final p = _recPath;
    _rolling = false;
    _dropping = true;
    await _toggleRec(); // stops
    _dropping = false;
    if (p != null) {
      try {
        await File(p).delete();
      } catch (_) {}
      try {
        await File(p.replaceFirst(RegExp(r'\.mp4$'), '.srt')).delete();
      } catch (_) {}
    }
  }

  /// Snapshot + alert to the viewer; a second "after" snapshot follows 3 s later.
  Future<void> _emitEvent(String kind, Uint8List? png, DateTime t) async {
    Uint8List? th;
    if (png != null) th = await _thumb(png);
    if (th != null) _saveEvent(th, t, kind);
    final ts = t.millisecondsSinceEpoch;
    try {
      _ws?.add(jsonEncode({
        'type': 'motion',
        'kind': kind,
        'ts': ts,
        if (th != null) 'img': base64Encode(th),
      }));
    } catch (_) {}
    PushQueue.send(
        kind == 'sound' ? 'صوت عالٍ عند الكاميرا' : 'حركة مكتشفة',
        fmtStamp(t),
        image: th);
    Future.delayed(const Duration(seconds: 3), () async {
      try {
        final tr = _stream?.getVideoTracks();
        if (tr == null || tr.isEmpty) return;
        final p2 = (await tr.first.captureFrame()).asUint8List();
        final th2 = await _thumb(p2);
        if (th2 == null) return;
        _saveEvent(th2, t, kind, '_b');
        _ws?.add(jsonEncode({
          'type': 'motion',
          'kind': kind,
          'ts': ts,
          'img2': base64Encode(th2),
        }));
      } catch (_) {}
    });
  }

  void _closeProbe() {
    final a = _probeA;
    final b = _probeB;
    _probeA = null;
    _probeB = null;
    a?.close();
    b?.close();
  }

  /// A private loop-back connection just to read the microphone level
  /// (works even when nobody is watching).
  Future<void> _ensureProbe() async {
    if (_probeA != null) return;
    final st = _stream;
    if (st == null) return;
    final at = st.getAudioTracks();
    if (at.isEmpty) {
      if (_soundOk != false) {
        _soundOk = false;
        _sendCfg();
      }
      return;
    }
    try {
      final conf = <String, dynamic>{
        'sdpSemantics': 'unified-plan',
        'iceServers': <Map<String, dynamic>>[],
      };
      final a = await createPeerConnection(conf);
      final b = await createPeerConnection(conf);
      _probeA = a;
      _probeB = b;
      a.onIceCandidate = (c) {
        b.addCandidate(c).catchError((_) {});
      };
      b.onIceCandidate = (c) {
        a.addCandidate(c).catchError((_) {});
      };
      await a.addTrack(at.first, st);
      final offer = await a.createOffer();
      await a.setLocalDescription(offer);
      await b.setRemoteDescription(offer);
      final ans = await b.createAnswer();
      await b.setLocalDescription(ans);
      await a.setRemoteDescription(ans);
    } catch (_) {
      _soundOk = false;
      _closeProbe();
      _sendCfg();
    }
  }

  Future<void> _soundTick() async {
    if (!_sOn || !_inSchedule()) {
      if (_probeA != null) _closeProbe();
      return;
    }
    await _ensureProbe();
    final a = _probeA;
    if (a == null) return;
    var lvl = -1.0;
    try {
      for (final r in await a.getStats()) {
        final v = r.values;
        final audio = '${v['kind'] ?? v['mediaType']}' == 'audio';
        if ((r.type == 'media-source' || r.type == 'track') &&
            audio &&
            v['audioLevel'] != null) {
          lvl = max(lvl, numOf(v['audioLevel']));
        }
      }
    } catch (_) {
      return;
    }
    if (lvl < 0) {
      _noLevel++;
      if (_noLevel > 20 && _soundOk != false) {
        _soundOk = false; // this phone does not report the mic level
        _sendCfg();
      }
      return;
    }
    if (_soundOk != true) {
      _soundOk = true;
      _sendCfg();
    }
    _lastLvl = lvl;
    final nowL = DateTime.now();
    if (nowL.difference(_lastLvlSent).inMilliseconds >= 900) {
      _lastLvlSent = nowL;
      try {
        _ws?.add(jsonEncode({'type': 'lvl', 'v': lvl}));
      } catch (_) {}
    }
    final mult = const [5.0, 3.5, 2.2][_mSens];
    final minL = const [0.12, 0.08, 0.05][_mSens];
    final thr = max(minL, _ambient * mult);
    if (lvl > thr) {
      _loudStreak++;
    } else {
      _loudStreak = 0;
      _ambient = _ambient * 0.9 + lvl * 0.1;
    }
    if (_loudStreak < 2) return;
    _loudStreak = 0;
    final now = DateTime.now();
    if (now.difference(_lastSound).inSeconds < _alertGap) return;
    _lastSound = now;
    _lastMotion = now;
    await _autoRecStart();
    Uint8List? png;
    final tr = _stream?.getVideoTracks();
    if (tr != null && tr.isNotEmpty) {
      try {
        png = (await tr.first.captureFrame()).asUint8List();
      } catch (_) {}
    }
    await _emitEvent('sound', png, now);
  }

  void _setSiren(bool on) {
    _sirenTimer?.cancel();
    if (!on) return;
    var n = 0;
    _sirenTimer = Timer.periodic(const Duration(milliseconds: 700), (t) {
      SystemSound.play(SystemSoundType.alert);
      HapticFeedback.vibrate();
      if (++n > 20) t.cancel();
    });
  }

  /// Power saving: black screen when nobody watches / records for a minute.
  void _idleTick() {
    if (!_idleDim) {
      if (_dim && mounted) setState(() => _dim = false);
      return;
    }
    final busy = _ws != null || _recShown;
    if (busy) {
      _idleSince = null;
      if (_dim && mounted) setState(() => _dim = false);
      return;
    }
    _idleSince ??= DateTime.now();
    if (!_dim && DateTime.now().difference(_idleSince!).inSeconds > 60) {
      if (mounted) setState(() => _dim = true);
    }
  }

  Future<Directory> _recDirectory() async =>
      (Platform.isAndroid ? await getExternalStorageDirectory() : null) ??
      await getApplicationDocumentsDirectory();

  /// Library API for the viewer (recordings + event snapshots), PIN protected.
  Future<void> _http(HttpRequest req) async {
    final remote = req.connectionInfo?.remoteAddress.address ?? '?';
    final res = req.response;
    try {
      final path = req.uri.path;
      if (path == '/web' || path == '/') {
        res.headers.contentType = ContentType.html;
        res.write(kWebPage);
        await res.close();
        return;
      }
      if (!path.startsWith('/lib/')) {
        res.write('LAN Cam');
        await res.close();
        return;
      }
      if (_locked(remote)) {
        res.statusCode = 429;
        await res.close();
        return;
      }
      final q = req.uri.queryParameters;
      final role = _roleFor('${q['pin'] ?? ''}');
      if (role == null) {
        _fails.putIfAbsent(remote, () => []).add(DateTime.now());
        res.statusCode = 403;
        await res.close();
        return;
      }
      _fails.remove(remote);
      res.headers.set('x-role', role);
      final recDir = await _recDirectory();
      final docsPath = (await getApplicationDocumentsDirectory()).path;
      final evtDir = Directory('$docsPath/events');
      final tlDir = Directory('$docsPath/timelapse');
      if (path == '/lib/log') {
        if (role != 'admin') {
          res.statusCode = 403;
        } else {
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode(_log));
        }
        await res.close();
        return;
      }
      if (path == '/lib/tl') {
        final names = <String>[];
        if (await tlDir.exists()) {
          await for (final e in tlDir.list()) {
            if (e is File && e.path.endsWith('.png')) {
              names.add(e.path.split('/').last);
            }
          }
        }
        names.sort();
        final day = q['d'];
        res.headers.contentType = ContentType.json;
        if (day == null) {
          final cnt = <String, int>{};
          for (final n in names) {
            final m = RegExp(r'tl_(\d{4}-\d{2}-\d{2})_').firstMatch(n);
            if (m != null) cnt[m.group(1)!] = (cnt[m.group(1)!] ?? 0) + 1;
          }
          res.write(jsonEncode([
            for (final e in cnt.entries) {'d': e.key, 'n': e.value}
          ]));
        } else {
          res.write(jsonEncode(names.where((n) => n.startsWith('tl_$day')).toList()));
        }
        await res.close();
        return;
      }
      if (path == '/lib/list') {
        final items = <Map<String, dynamic>>[];
        if (await recDir.exists()) {
          await for (final e in recDir.list()) {
            if (e is File && RegExp(r'cam_[^/]*\.mp4$').hasMatch(e.path)) {
              final st = await e.stat();
              items.add({
                'k': 'rec',
                'n': e.path.split('/').last,
                's': st.size,
                't': st.modified.millisecondsSinceEpoch,
              });
            }
          }
        }
        if (await evtDir.exists()) {
          await for (final e in evtDir.list()) {
            if (e is File &&
                e.path.endsWith('.png') &&
                !e.path.endsWith('_b.png')) {
              final st = await e.stat();
              items.add({
                'k': 'evt',
                'n': e.path.split('/').last,
                's': st.size,
                't': st.modified.millisecondsSinceEpoch,
              });
            }
          }
        }
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode(items));
        await res.close();
        return;
      }
      final name = q['n'] ?? '';
      final kind = q['k'] ?? '';
      if (name.isEmpty || name.contains('/') || name.contains('..')) {
        res.statusCode = 400;
        await res.close();
        return;
      }
      final dir = kind == 'evt' ? evtDir : (kind == 'tl' ? tlDir : recDir);
      final f = File('${dir.path}/$name');
      if (path == '/lib/file') {
        if (!await f.exists()) {
          res.statusCode = 404;
          await res.close();
          return;
        }
        res.headers.contentType = ContentType.binary;
        res.contentLength = await f.length();
        await res.addStream(f.openRead());
        await res.close();
        return;
      }
      if (path == '/lib/del') {
        if (role != 'admin') {
          res.statusCode = 403;
          await res.close();
          return;
        }
        try {
          if (kind == 'tl') {
            if (await tlDir.exists()) {
              await for (final e in tlDir.list()) {
                if (e is File && e.path.split('/').last.startsWith('tl_$name')) {
                  try {
                    await e.delete();
                  } catch (_) {}
                }
              }
            }
          } else if (await f.exists()) {
            await f.delete();
          }
          if (kind == 'rec') {
            final srt = File(f.path.replaceFirst(RegExp(r'\.mp4$'), '.srt'));
            if (await srt.exists()) await srt.delete();
          } else {
            final b = File(f.path.replaceFirst(RegExp(r'\.png$'), '_b.png'));
            if (await b.exists()) await b.delete();
          }
        } catch (_) {}
        res.write('ok');
        await res.close();
        return;
      }
      res.statusCode = 404;
      await res.close();
    } catch (_) {
      try {
        res.statusCode = 500;
        await res.close();
      } catch (_) {}
    }
  }

  // ───────────── WebDAV / daily summary / time-lapse ─────────────
  Future<void> _wdUpload(String? p) async {
    if (p == null) return;
    final s = await loadSettings();
    if (!wdConfigured(s)) return;
    _wdPending.add(p);
    await _wdFlush();
  }

  Future<void> _wdFlush() async {
    for (final p in _wdPending.toList()) {
      final f = File(p);
      if (!await f.exists()) {
        _wdPending.remove(p);
        continue;
      }
      final ok = await webdavPut(f);
      if (!ok) break;
      final srt = File(p.replaceFirst(RegExp(r'\.mp4$'), '.srt'));
      if (await srt.exists()) await webdavPut(srt);
      _wdPending.remove(p);
    }
  }

  void _dailyCheck() {
    final n = DateTime.now();
    if (_dailyHour >= 0 &&
        n.hour == _dailyHour &&
        n.minute == 0 &&
        _lastSummaryDay != n.day) {
      _lastSummaryDay = n.day;
      _sendDaily();
    }
  }

  Future<void> _sendDaily() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}/events');
      final names = <String>[];
      if (await dir.exists()) {
        await for (final e in dir.list()) {
          if (e is File && !e.path.endsWith('_b.png')) {
            names.add(e.path.split('/').last);
          }
        }
      }
      final d = summarizeEvents(names, DateTime.now());
      PushQueue.send('ملخص اليوم', d.text('اليوم'));
    } catch (_) {}
  }

  /// One small frame every N minutes (played back in the library).
  Future<void> _tlTick() async {
    if (_tl <= 0 || _stream == null) return;
    final now = DateTime.now();
    if (now.difference(_lastTl).inSeconds < _tl * 60) return;
    _lastTl = now;
    try {
      final tr = _stream!.getVideoTracks();
      if (tr.isEmpty) return;
      final png = (await tr.first.captureFrame()).asUint8List();
      final th = await _thumb(png, 256);
      if (th == null) return;
      final base = await getApplicationDocumentsDirectory();
      final dir = Directory('${base.path}/timelapse');
      if (!await dir.exists()) await dir.create(recursive: true);
      await File('${dir.path}/tl_${fmtFile(now)}.png').writeAsBytes(th);
      final files = <File>[];
      var total = 0;
      await for (final e in dir.list()) {
        if (e is File) {
          files.add(e);
          total += await e.length();
        }
      }
      if (total > 150 * 1024 * 1024) {
        files.sort((a, b) => a.path.compareTo(b.path));
        for (final f in files) {
          if (total <= 120 * 1024 * 1024) break;
          total -= await f.length();
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  int _homeCode() {
    if (_homeUntil == -1) return -1;
    final left = _homeUntil - DateTime.now().millisecondsSinceEpoch;
    return left > 0 ? (left ~/ 3600000) + 1 : 0;
  }

  /// No movement for N hours (elder care).
  void _careCheck() {
    if (_lastMotion.isAfter(_careBase)) {
      _careBase = _lastMotion;
      _careAlerted = false;
    }
    if (_care <= 0 || !_mOn || !_inSchedule() || _careAlerted) return;
    if (DateTime.now().difference(_careBase).inMinutes < _care * 60) return;
    _careAlerted = true;
    PushQueue.send('لا توجد حركة', 'لا توجد حركة منذ $_care ساعات');
    try {
      _ws?.add(jsonEncode({
        'type': 'motion',
        'kind': 'care',
        'ts': DateTime.now().millisecondsSinceEpoch,
      }));
    } catch (_) {}
  }

  /// Plain HTTP link for iOS Shortcuts: /mode?pin=PIN&home=1|0 (or &h=hours).
  Future<void> _startAutoServer() async {
    try {
      _autoSrv = await HttpServer.bind(InternetAddress.anyIPv4, 8082);
      _autoSrv!.listen((req) async {
        final remote = req.connectionInfo?.remoteAddress.address ?? '?';
        final res = req.response;
        try {
          final q = req.uri.queryParameters;
          if (_locked(remote)) {
            res.statusCode = 429;
          } else if (req.uri.path == '/mode' && q['pin'] == _pin) {
            _fails.remove(remote);
            final h = int.tryParse(q['h'] ?? '') ?? (q['home'] == '1' ? -1 : 0);
            _applyCfg({'home': h});
            res.write('ok');
          } else {
            _fails.putIfAbsent(remote, () => []).add(DateTime.now());
            res.statusCode = 403;
          }
        } catch (_) {}
        await res.close();
      });
    } catch (_) {}
  }

  Future<void> _loadLog() async {
    try {
      final base = await getApplicationDocumentsDirectory();
      final f = File('${base.path}/access_log.json');
      if (await f.exists()) {
        final l = jsonDecode(await f.readAsString()) as List;
        _log
          ..clear()
          ..addAll(l.map((e) => Map<String, dynamic>.from(e as Map)));
      }
    } catch (_) {}
  }

  Future<void> _logAccess(String ip, String role, String kind) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (_log.isNotEmpty &&
        _log.first['ip'] == ip &&
        _log.first['role'] == role &&
        nowMs - (_log.first['t'] as int) < 120000) {
      return;
    }
    _log.insert(0, {'t': nowMs, 'ip': ip, 'role': role, 'kind': kind});
    if (_log.length > 100) _log.removeLast();
    try {
      final base = await getApplicationDocumentsDirectory();
      await File('${base.path}/access_log.json').writeAsString(jsonEncode(_log));
    } catch (_) {}
    final st = await loadSettings();
    final known = <String>{
      for (final e in ((st['knownViewers'] as List?) ?? const [])) '$e',
    };
    if (known.isEmpty) {
      known.add(ip); // first ever viewer: remember silently
      await saveSettings({'knownViewers': known.toList()});
      return;
    }
    if (!known.contains(ip)) {
      known.add(ip);
      await saveSettings({'knownViewers': known.toList()});
      PushQueue.send('مشاهدة جديدة',
          'جهاز جديد ($ip) دخل بصلاحية ${role == 'admin' ? 'تحكم كامل' : 'مشاهدة فقط'}');
    }
  }

  void _toggleChargeStart(bool v) {
    setState(() => _chargeStart = v);
    saveSettings({'chargeStart': v});
    _svc
        .invokeMethod('config', {'always': _always, 'pin': _pin, 'charge': v})
        .catchError((_) {});
  }

  void _showQr() {
    final cands = _ips.isEmpty ? [MapEntry('wifi', _ip)] : _ips;
    var sel = cands.indexWhere((e) => e.value == _ip);
    if (sel < 0) sel = 0;
    var useView = false;
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
                data: 'LANCAM|${cands[sel].value}|$kPort|${useView ? _viewPin : _pin}',
                version: QrVersions.auto,
                size: 210,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 10),
            Text('${cands[sel].value}  (${cands[sel].key})',
                textDirection: TextDirection.ltr,
                style: const TextStyle(fontSize: 12, color: Colors.white70)),
            Wrap(spacing: 6, children: [
              ChoiceChip(
                  label: const Text('تحكم كامل', style: TextStyle(fontSize: 11)),
                  selected: !useView,
                  onSelected: (_) => setM(() => useView = false)),
              ChoiceChip(
                  label: const Text('مشاهدة فقط', style: TextStyle(fontSize: 11)),
                  selected: useView,
                  onSelected: (_) => setM(() => useView = true)),
            ]),
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
        case 'touch':
          // normalised 0..1 (the phone may rotate at any time)
          _svc.invokeMethod('touch', {
            'a': d['a'],
            'x': (d['x'] as num).toDouble(),
            'y': (d['y'] as num).toDouble(),
          });
          break;
      }
    } catch (_) {}
  }

  Future<void> _startScreen() async {
    final cfg = await loadSettings();
    try {
      await _svc.invokeMethod('screenConfig', {
        'fps': (cfg['sfps'] as int?) ?? 60,
        'quality': (cfg['squality'] as int?) ?? 50,
        'maxSide': (cfg['sside'] as int?) ?? 960,
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
    if (d['cmd'] == 'cfg') {
      _applyCfg(d);
      return;
    }
    if (d['cmd'] == 'siren') {
      _setSiren(d['on'] == true);
      return;
    }
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
      _ws?.add(jsonEncode({'type': 'rec', 'on': _recShown, 'ok': ok}));
    } catch (_) {}
  }

  Future<void> _setRec(bool on) async {
    if (!Platform.isAndroid) {
      _sendRec(ok: false);
      return;
    }
    _autoRec = false;
    if (_rolling) {
      if (on && mounted) setState(() => _rolling = false);
      _sendRec();
      return;
    }
    if (on != _recording) await _toggleRec();
    _sendRec();
  }

  Future<void> _toggleRec() async {
    if (!Platform.isAndroid) return; // flutter_webrtc recorder: Android only
    if (_recording) {
      await _rec?.stop();
      final donePath = _recPath;
      await _stopSrt();
      if (mounted) setState(() => _recording = false);
      if (!_dropping) _wdUpload(donePath);
      _enforceLoop();
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
    _recPath = path;
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
    _motionTimer?.cancel();
    _loopTimer?.cancel();
    _soundTimer?.cancel();
    _preTimer?.cancel();
    _pushTimer?.cancel();
    _tlTimer?.cancel();
    _autoSrv?.close(force: true);
    _sirenTimer?.cancel();
    _closeProbe();
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
            const SizedBox(height: 8),
            InfoRow(
              label: 'رمز المشاهدة فقط',
              value: _viewPin,
              trailing: IconButton(
                icon: const Icon(Icons.refresh_rounded, size: 20),
                onPressed: () {
                  setState(() => _viewPin = _newPin());
                  saveSettings({'viewpin': _viewPin});
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
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                  kTls ? 'الاتصال مشفّر (TLS)' : 'الاتصال غير مشفّر — أضف شهادة TLS في البناء',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 11, color: kTls ? kGreen : Colors.amber)),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SelectableText('${kTls ? 'https' : 'http'}://$_ip:$kPort/web',
                  textAlign: TextAlign.center,
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
            ),
            const SizedBox(height: 10),
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
                title: const Text('كشف الحركة',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                subtitle: const Text('الإعدادات الكاملة من جهاز المشاهدة (زر الأمان)',
                    style: TextStyle(fontSize: 11, color: Colors.white54)),
                value: _mOn,
                onChanged: (v) => _applyCfg({'on': v}),
              ),
            ),
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
                title: const Text('توفير الطاقة',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                subtitle: const Text('شاشة سوداء إذا لم يشاهد أحد لمدة دقيقة',
                    style: TextStyle(fontSize: 11, color: Colors.white54)),
                value: _idleDim,
                onChanged: (v) => _applyCfg({'idle': v}),
              ),
            ),
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
            if (Platform.isAndroid && _always)
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
                  title: const Text('بدء الكاميرا عند الشحن',
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                  subtitle: const Text('وصّل الشاحن فتبدأ الكاميرا تلقائياً',
                      style: TextStyle(fontSize: 11, color: Colors.white54)),
                  value: _chargeStart,
                  onChanged: _toggleChargeStart,
                ),
              ),
            if (Platform.isAndroid && _always) _diagBox(),
            if (Platform.isAndroid) _screenBox(),
            if (Platform.isAndroid)
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: _recShown ? kRed : null,
                  minimumSize: const Size.fromHeight(46),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                ),
                icon: Icon(_recShown ? Icons.stop_rounded : Icons.fiber_manual_record),
                label: Text(_recShown ? 'إيقاف التسجيل' : 'تسجيل'),
                onPressed: () async {
                  _autoRec = false;
                  if (_rolling) {
                    // keep the running pre-roll segment as a normal recording
                    setState(() => _rolling = false);
                    _sendRec();
                    return;
                  }
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
          if (!_dim) RTCVideoView(_local),
          if (_clockOn)
            Positioned(left: 10, bottom: 10, child: ClockStamp(time: _now)),
          if (_motionNow)
            const Positioned(
                left: 10, top: 10, child: Pill(color: kRed, text: 'حركة')),
          Positioned(
            top: 10,
            right: 10,
            child: Row(children: [
              Pill(
                  color: _live ? kRed : Colors.grey,
                  text: _live ? 'LIVE' : 'STANDBY'),
              if (_recShown) ...[
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
  Widget build(BuildContext context) => Stack(children: [
        _buildMain(),
        if (_dim)
          Positioned.fill(
            child: Material(
              color: Colors.black,
              child: InkWell(
                onTap: () => setState(() {
                  _dim = false;
                  _idleSince = DateTime.now();
                }),
                child: const Center(
                  child: Text('وضع توفير الطاقة — المس الشاشة',
                      style: TextStyle(color: Colors.white24, fontSize: 12)),
                ),
              ),
            ),
          ),
      ]);

  Widget _buildMain() => Scaffold(
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
  int _alertBat = 20;
  int _alertTemp = 45;
  bool _alertSnd = true;
  bool _alertHap = true;
  bool _autoRetry = true;
  int _prevLost = 0;
  int _prevRecv = 0;
  bool _alertedBat20 = false;
  bool _alertedBat10 = false;
  bool _alertedTemp = false;
  final _tc = TransformationController();
  // phone-screen mirror: auto orientation, hide-able buttons, live touch
  bool? _screenLand;
  final _uiImg = ValueNotifier<ui.Image?>(null);
  bool _decoding = false;
  Uint8List? _pendingFrame;
  final _touchPos = ValueNotifier<Offset?>(null);
  int? _ptr;
  DateTime _lastMove = DateTime.fromMillisecondsSinceEpoch(0);
  bool _barOn = false;
  Timer? _barTimer;
  String _role = 'admin'; // admin | view (view-only PIN)
  bool _backupOn = false;
  bool _backingUp = false;
  final _lvlN = ValueNotifier<double>(0);
  static const Map<String, Map<String, dynamic>> _profiles = {
    'منزل': {
      'on': true, 'rec': false, 'sens': 1, 'filter': true,
      'son': false, 'sched': false, 'pre': false,
    },
    'غرفة طفل': {
      'on': false, 'son': true, 'sens': 2, 'sched': false,
      'rec': false, 'pre': false,
    },
    'حيوان أليف': {
      'on': true, 'sens': 2, 'filter': false, 'rec': true, 'loop': 2048,
      'son': false, 'sched': false, 'pre': false,
    },
    'متجر': {
      'on': true, 'sens': 1, 'filter': true, 'rec': true, 'loop': 5120,
      'son': false, 'sched': true, 'sh': 20, 'eh': 8, 'pre': false,
    },
  };
  // security (motion / zones / events)
  Map<String, dynamic> _cfg = {};
  final List<_Evt> _events = [];
  int _unread = 0;
  bool _zoneEdit = false;
  List<bool> _zEdit = List<bool>.filled(48, false);
  String _zEditMode = 'ignore';
  bool? _zPaint;

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
        _alertBat = (s['alertBat'] as int?) ?? 20;
        _alertTemp = (s['alertTemp'] as int?) ?? 45;
        _alertSnd = (s['alertSound'] as bool?) ?? true;
        _alertHap = (s['alertHaptic'] as bool?) ?? true;
        _autoRetry = (s['autoRetry'] as bool?) ?? true;
        _muted = s['muteStart'] == true;
        _backupOn = s['autoBackup'] == true;
      });
      if (s['keepOn'] == false) WakelockPlus.disable();
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
    if (!_autoRetry) {
      _wantLive = false;
      setState(() {
        _isConnected = false;
        _status = '${why ?? 'انقطع الاتصال'} — إعادة الاتصال التلقائية معطّلة';
      });
      return;
    }
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
      final ws = _ws = await openWs(ip).timeout(const Duration(seconds: 5));

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
          if (_backupOn) _autoBackup();
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
          case 'cfg':
            if (mounted) setState(() => _cfg = Map<String, dynamic>.from(d));
            break;
          case 'role':
            if (mounted) setState(() => _role = '${d['role']}');
            break;
          case 'lvl':
            _lvlN.value = numOf(d['v']);
            break;
          case 'motion':
            _onMotion(d as Map);
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
    if (_alertHap) HapticFeedback.heavyImpact();
    if (_alertSnd) SystemSound.play(SystemSoundType.alert);
    Speaker.say(m);
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
      if (chg || bat > _alertBat + 5) {
        _alertedBat20 = false;
        _alertedBat10 = false;
      } else if (bat <= _alertBat ~/ 2 && !_alertedBat10) {
        _alertedBat10 = true;
        _alertedBat20 = true;
        _alert('بطارية الكاميرا ${bat.toInt()}% — وصّلها بالشاحن');
      } else if (bat <= _alertBat && !_alertedBat20) {
        _alertedBat20 = true;
        _alert('بطارية الكاميرا منخفضة ${bat.toInt()}%');
      }
    }
    final t = m['temp'];
    if (t is num) {
      if (t >= _alertTemp && !_alertedTemp) {
        _alertedTemp = true;
        _alert('حرارة جهاز الكاميرا مرتفعة ${t.toStringAsFixed(0)}°');
      } else if (t < _alertTemp - 4) {
        _alertedTemp = false;
      }
    }
    if (m['range'] is bool) _range = m['range'] as bool;
    if (mounted) setState(() => _health = m);
  }

  /// Link quality as measured on this phone (RTT + packet loss).
  int _thumbTick = 0;

  /// Copies new camera recordings to Photos (once per connection).
  Future<void> _autoBackup() async {
    if (_backingUp || widget.screen) return;
    _backingUp = true;
    final ip = _ipCtl.text.trim();
    final c = tlsClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final st = await loadSettings();
      final key = 'backed_${ip.replaceAll('.', '_')}';
      final done = <String>{
        for (final e in ((st[key] as List?) ?? const [])) '$e',
      };
      Uri u(String path, [Map<String, String> q = const {}]) {
        final qp = {'pin': _pinCtl.text, ...q};
        return kTls
            ? Uri.https('$ip:$kPort', path, qp)
            : Uri.http('$ip:$kPort', path, qp);
      }

      final res = await (await c.getUrl(u('/lib/list'))).close();
      if (res.statusCode != 200) {
        await res.drain();
        return;
      }
      final items = (jsonDecode(await res.transform(utf8.decoder).join()) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((e) => e['k'] == 'rec')
          .toList();
      final camNow = DateTime.now().millisecondsSinceEpoch + _camOffsetMs;
      var n = 0;
      for (final it in items) {
        final name = '${it['n']}';
        if (done.contains(name)) continue;
        if (camNow - (it['t'] as num).toInt() < 60000) continue; // still being written
        final r = await (await c.getUrl(u('/lib/file', {'k': 'rec', 'n': name}))).close();
        if (r.statusCode != 200) {
          await r.drain();
          continue;
        }
        final dir = await getTemporaryDirectory();
        final f = File('${dir.path}/$name');
        final sink = f.openWrite();
        await sink.addStream(r);
        await sink.close();
        if (!await Gal.hasAccess()) await Gal.requestAccess();
        await Gal.putVideo(f.path);
        try {
          await f.delete();
        } catch (_) {}
        done.add(name);
        n++;
        await saveSettings({key: done.toList()});
      }
      if (n > 0 && mounted) _snack('تم نسخ $n تسجيل إلى الصور تلقائياً');
    } catch (_) {
    } finally {
      c.close(force: true);
      _backingUp = false;
    }
  }

  /// Keep a small last-seen picture per camera (used by the multi-camera grid).
  Future<void> _saveThumb() async {
    try {
      final tr = _remote.srcObject?.getVideoTracks();
      if (tr == null || tr.isEmpty) return;
      final png = (await tr.first.captureFrame()).asUint8List();
      final th = await pngThumb(png, 360);
      if (th == null) return;
      await (await thumbFile(_ipCtl.text.trim())).writeAsBytes(th);
      kThumbRev.value++;
    } catch (_) {}
  }

  Future<void> _pollStats() async {
    final pc = _pc;
    if (pc == null || !_isConnected || widget.screen) return;
    if (_thumbTick++ % 15 == 5) _saveThumb();
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
    if (_zoneEdit) {
      return Stack(fit: StackFit.expand, children: [v, _zoneOverlay()]);
    }
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

  void _onMotion(Map d) {
    try {
      final ts = (d['ts'] as num).toInt();
      final kind = '${d['kind'] ?? 'motion'}';
      if (d['img2'] != null) {
        final i = _events.indexWhere((e) => e.t.millisecondsSinceEpoch == ts);
        if (i >= 0) {
          _events[i].img2 = base64Decode('${d['img2']}');
          if (mounted) setState(() {});
        }
        return;
      }
      final img = d['img'] != null ? base64Decode('${d['img']}') : Uint8List(0);
      _events.insert(
          0, _Evt(DateTime.fromMillisecondsSinceEpoch(ts), img, kind));
      if (_events.length > 30) _events.removeLast();
      _unread++;
      _alert(kind == 'sound'
          ? 'صوت عالٍ عند الكاميرا'
          : (kind == 'care'
              ? 'لا توجد حركة منذ فترة طويلة — تحقق من الشخص'
              : 'حركة مكتشفة في الكاميرا'));
    } catch (_) {}
  }

  void _cfgSend(Map<String, dynamic> patch) {
    setState(() => _cfg = {..._cfg, ...patch});
    _send({'type': 'cmd', 'cmd': 'cfg', ...patch});
  }

  Rect _videoRect(Size box) {
    final vw = _remote.videoWidth;
    final vh = _remote.videoHeight;
    if (vw <= 0 || vh <= 0 || _fitCover) {
      return Rect.fromLTWH(0, 0, box.width, box.height);
    }
    final sc = min(box.width / vw, box.height / vh);
    final w = vw * sc;
    final h = vh * sc;
    return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
  }

  /// Paint the detection zones over the live picture (8 x 6 grid).
  Widget _zoneOverlay() => LayoutBuilder(builder: (context, c) {
        final r = _videoRect(Size(c.maxWidth, c.maxHeight));
        final cw = r.width / 8;
        final chh = r.height / 6;
        int? idx(Offset p) {
          final x = ((p.dx - r.left) / cw).floor();
          final y = ((p.dy - r.top) / chh).floor();
          if (x < 0 || x >= 8 || y < 0 || y >= 6) return null;
          return y * 8 + x;
        }

        void paintAt(Offset p) {
          final i = idx(p);
          final v = _zPaint;
          if (i == null || v == null) return;
          if (_zEdit[i] != v) setState(() => _zEdit[i] = v);
        }

        final col = _zEditMode == 'ignore'
            ? const Color(0x66EF4444)
            : const Color(0x6622C55E);
        return Stack(fit: StackFit.expand, children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              final i = idx(d.localPosition);
              if (i != null) setState(() => _zEdit[i] = !_zEdit[i]);
            },
            onPanStart: (d) {
              final i = idx(d.localPosition);
              if (i == null) return;
              _zPaint = !_zEdit[i];
              paintAt(d.localPosition);
            },
            onPanUpdate: (d) => paintAt(d.localPosition),
            child: Stack(children: [
              for (var i = 0; i < 48; i++)
                Positioned(
                  left: r.left + (i % 8) * cw,
                  top: r.top + (i ~/ 8) * chh,
                  width: cw,
                  height: chh,
                  child: Container(
                    decoration: BoxDecoration(
                      color: _zEdit[i] ? col : Colors.transparent,
                      border: Border.all(color: Colors.white24, width: 0.5),
                    ),
                  ),
                ),
            ]),
          ),
          Positioned(
            top: 6,
            left: 6,
            right: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xCC000000),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                children: [
                  ChoiceChip(
                    label: const Text('تجاهل المناطق', style: TextStyle(fontSize: 11)),
                    selected: _zEditMode == 'ignore',
                    onSelected: (_) => setState(() => _zEditMode = 'ignore'),
                  ),
                  ChoiceChip(
                    label: const Text('مراقبة المناطق فقط', style: TextStyle(fontSize: 11)),
                    selected: _zEditMode == 'only',
                    onSelected: (_) => setState(() => _zEditMode = 'only'),
                  ),
                  TextButton(
                    onPressed: () =>
                        setState(() => _zEdit = List<bool>.filled(48, false)),
                    child: const Text('مسح'),
                  ),
                  FilledButton(
                    onPressed: () {
                      _cfgSend({
                        'zmask': _zEdit.map((e) => e ? '1' : '0').join(),
                        'zmode': _zEditMode,
                      });
                      setState(() => _zoneEdit = false);
                    },
                    child: const Text('تم'),
                  ),
                ],
              ),
            ),
          ),
        ]);
      });

  void _security() {
    showModalBottomSheet(
      context: context,
      backgroundColor: kSurface,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setM) {
          void cfg(Map<String, dynamic> p) {
            _cfgSend(p);
            setM(() {});
          }

          final sens = ((_cfg['sens'] as num?) ?? 1).toInt();
          final loop = ((_cfg['loop'] as num?) ?? 0).toInt();
          final android = _cfg['android'] != false;
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('الأمان والمراقبة الذكية',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, children: [
                      for (final p in _profiles.entries)
                        ActionChip(
                          avatar: const Icon(Icons.auto_fix_high_rounded, size: 16),
                          label: Text(p.key),
                          onPressed: () {
                            cfg(Map<String, dynamic>.from(p.value));
                            _snack('تم تطبيق ملف "${p.key}"');
                          },
                        ),
                    ]),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('كشف الحركة'),
                      subtitle: const Text('تنبيه مع لقطة عند وجود حركة',
                          style: TextStyle(fontSize: 11, color: Colors.white54)),
                      value: _cfg['on'] == true,
                      onChanged: (v) => cfg({'on': v}),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('تسجيل تلقائي عند الحركة'),
                      subtitle: Text(
                          android
                              ? 'يبدأ عند الحركة ويتوقف بعد 15 ث من آخر حركة'
                              : 'غير متاح: جهاز الكاميرا لا يدعم التسجيل (Android فقط)',
                          style: const TextStyle(fontSize: 11, color: Colors.white54)),
                      value: _cfg['rec'] == true,
                      onChanged: android ? (v) => cfg({'rec': v}) : null,
                    ),
                    const SizedBox(height: 4),
                    const Text('الحساسية'),
                    Wrap(spacing: 8, children: [
                      for (var i = 0; i < 3; i++)
                        ChoiceChip(
                          label: Text(const ['منخفضة', 'متوسطة', 'عالية'][i]),
                          selected: sens == i,
                          onSelected: (_) => cfg({'sens': i}),
                        ),
                    ]),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('تصفية الإنذارات الكاذبة'),
                      subtitle: const Text(
                          'يتجاهل الحركة الصغيرة (حشرات) وتغيّر الإضاءة والوميض. ليس تعرّفاً على الأشخاص.',
                          style: TextStyle(fontSize: 11, color: Colors.white54)),
                      value: _cfg['filter'] != false,
                      onChanged: (v) => cfg({'filter': v}),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('تسجيل ما قبل الحركة'),
                      subtitle: const Text(
                          'يحتفظ بحتى 10 ث قبل الحركة. يسجّل باستمرار على الكاميرا فيزيد البطارية والكتابة على التخزين (Android فقط، مع التسجيل التلقائي).',
                          style: TextStyle(fontSize: 11, color: Colors.white54)),
                      value: _cfg['pre'] == true,
                      onChanged: (android && _cfg['rec'] == true)
                          ? (v) => cfg({'pre': v})
                          : null,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('اعتماد الأشخاص فقط'),
                      subtitle: Text(
                          _cfg['personAvail'] == true
                              ? 'الحركة تُعتمد فقط إذا ظهر وجه أو جسم شخص في الصورة'
                              : 'غير مفعّل في هذا الإصدار: شغّل البناء مع خيار ml',
                          style: const TextStyle(fontSize: 11, color: Colors.white54)),
                      value: _cfg['person'] == true,
                      onChanged: _cfg['personAvail'] == true
                          ? (v) => cfg({'person': v})
                          : null,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('كشف الصوت'),
                      subtitle: Text(
                          _cfg['sound'] == false
                              ? 'غير مدعوم: هذا الجهاز لا يعطي مستوى الميكروفون'
                              : 'تنبيه عند صوت أعلى بكثير من الهدوء المعتاد (بكاء، زجاج، نباح)',
                          style: const TextStyle(fontSize: 11, color: Colors.white54)),
                      value: _cfg['son'] == true,
                      onChanged: (v) => cfg({'son': v}),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('جدول زمني'),
                      subtitle: const Text('الحركة والصوت يعملان في هذه الساعات فقط',
                          style: TextStyle(fontSize: 11, color: Colors.white54)),
                      value: _cfg['sched'] == true,
                      onChanged: (v) => cfg({'sched': v}),
                    ),
                    if (_cfg['sched'] == true)
                      Row(children: [
                        const Text('من'),
                        const SizedBox(width: 8),
                        DropdownButton<int>(
                          value: ((_cfg['sh'] as num?) ?? 22).toInt(),
                          items: [
                            for (var h = 0; h < 24; h++)
                              DropdownMenuItem(value: h, child: Text('${two(h)}:00')),
                          ],
                          onChanged: (v) {
                            if (v != null) cfg({'sh': v});
                          },
                        ),
                        const SizedBox(width: 16),
                        const Text('إلى'),
                        const SizedBox(width: 8),
                        DropdownButton<int>(
                          value: ((_cfg['eh'] as num?) ?? 6).toInt(),
                          items: [
                            for (var h = 0; h < 24; h++)
                              DropdownMenuItem(value: h, child: Text('${two(h)}:00')),
                          ],
                          onChanged: (v) {
                            if (v != null) cfg({'eh': v});
                          },
                        ),
                      ]),
                    const Divider(),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.video_library_rounded),
                      title: const Text('مكتبة التسجيلات والأحداث'),
                      subtitle: const Text('تصفح وتنزيل وحذف من جهاز الكاميرا',
                          style: TextStyle(fontSize: 11, color: Colors.white54)),
                      onTap: () {
                        Navigator.pop(ctx);
                        Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => LibraryPage(
                                    ip: _ipCtl.text.trim(), pin: _pinCtl.text)));
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.history_rounded),
                      title: const Text('سجل الدخول'),
                      subtitle: const Text('تُسجَّل كل مشاهدة مع التاريخ والجهاز',
                          style: TextStyle(fontSize: 11, color: Colors.white54)),
                      onTap: () {
                        Navigator.pop(ctx);
                        Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => AccessLogPage(
                                    ip: _ipCtl.text.trim(), pin: _pinCtl.text)));
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.campaign_rounded),
                      title: const Text('تشغيل صفارة على الكاميرا'),
                      subtitle: const Text('نغمة تنبيه واهتزاز لمدة 15 ثانية',
                          style: TextStyle(fontSize: 11, color: Colors.white54)),
                      trailing: Wrap(children: [
                        TextButton(
                            onPressed: () => _send(
                                {'type': 'cmd', 'cmd': 'siren', 'on': true}),
                            child: const Text('تشغيل')),
                        TextButton(
                            onPressed: () => _send(
                                {'type': 'cmd', 'cmd': 'siren', 'on': false}),
                            child: const Text('إيقاف')),
                      ]),
                    ),
                    const Divider(),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.grid_on_rounded),
                      title: const Text('تحديد مناطق الكشف'),
                      subtitle: Text(
                          _cfg['zmode'] == 'only'
                              ? 'الوضع: مراقبة المناطق المرسومة فقط'
                              : 'الوضع: تجاهل المناطق المرسومة',
                          style: const TextStyle(fontSize: 11, color: Colors.white54)),
                      onTap: () {
                        final m = '${_cfg['zmask'] ?? ''}';
                        setState(() {
                          _zEdit = List<bool>.generate(
                              48, (i) => m.length == 48 && m[i] == '1');
                          _zEditMode = _cfg['zmode'] == 'only' ? 'only' : 'ignore';
                          _zoneEdit = true;
                        });
                        Navigator.pop(ctx);
                        if (!_wide) _setWide(true);
                      },
                    ),
                    const Divider(),
                    const Text('تسجيل دوّار (حذف الأقدم تلقائياً)'),
                    Wrap(spacing: 8, children: [
                      for (final v in const [0, 1024, 2048, 5120, 10240])
                        ChoiceChip(
                          label: Text(v == 0 ? 'إيقاف' : '${v ~/ 1024} GB'),
                          selected: loop == v,
                          onSelected: android ? (_) => cfg({'loop': v}) : null,
                        ),
                    ]),
                    const Divider(),
                    const Text('أنا في المنزل (إيقاف الكشف)'),
                    Wrap(spacing: 8, children: [
                      for (var i = 0; i < 4; i++)
                        ChoiceChip(
                          label: Text(const ['إيقاف', 'ساعتان', '8 ساعات', 'حتى أوقفه'][i]),
                          selected: homeSel(((_cfg['home'] as num?) ?? 0).toInt(),
                              const [0, 2, 8, -1][i]),
                          onSelected: (_) => cfg({'home': const [0, 2, 8, -1][i]}),
                        ),
                    ]),
                    const SizedBox(height: 8),
                    const Text('رعاية كبار السن: تنبيه إن لم تُرصد حركة'),
                    Wrap(spacing: 8, children: [
                      for (var i = 0; i < 5; i++)
                        ChoiceChip(
                          label: Text(const ['إيقاف', '2 س', '4 س', '8 س', '12 س'][i]),
                          selected: ((_cfg['care'] as num?) ?? 0).toInt() ==
                              const [0, 2, 4, 8, 12][i],
                          onSelected: (_) => cfg({'care': const [0, 2, 4, 8, 12][i]}),
                        ),
                    ]),
                    const Divider(),
                    const Text('تصوير زمني (لقطة كل)'),
                    Wrap(spacing: 8, children: [
                      for (final v in const [0, 1, 2, 5, 10])
                        ChoiceChip(
                          label: Text(v == 0 ? 'إيقاف' : '$v د'),
                          selected: ((_cfg['tl'] as num?) ?? 0).toInt() == v,
                          onSelected: (_) => cfg({'tl': v}),
                        ),
                    ]),
                    if (_cfg['rec'] == true && loop == 0)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                            'تنبيه: التسجيل التلقائي بدون تسجيل دوّار قد يملأ التخزين.',
                            style: TextStyle(fontSize: 11, color: Colors.amber)),
                      ),
                  ]),
            ),
          );
        },
      ),
    );
  }

  void _eventsSheet() {
    setState(() => _unread = 0);
    showModalBottomSheet(
      context: context,
      backgroundColor: kSurface,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.6,
          child: _events.isEmpty
              ? const Center(
                  child: Text('لا توجد أحداث بعد',
                      style: TextStyle(color: Colors.white54)))
              : GridView.count(
                  padding: const EdgeInsets.all(12),
                  crossAxisCount: 2,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 16 / 10,
                  children: [
                    for (final e in _events)
                      GestureDetector(
                        onTap: () => _showEvent(e),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Stack(fit: StackFit.expand, children: [
                            Image.memory(e.img,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Center(
                                    child: Icon(
                                        e.kind == 'sound'
                                            ? Icons.hearing_rounded
                                            : Icons.image_not_supported_outlined,
                                        color: Colors.white38))),
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: Container(
                                color: const Color(0x99000000),
                                padding: const EdgeInsets.all(4),
                                child: Text(fmtStamp(e.t),
                                    textDirection: TextDirection.ltr,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(fontSize: 10)),
                              ),
                            ),
                          ]),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  void _showEvent(_Evt e) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSurface,
        contentPadding: const EdgeInsets.all(10),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('لحظة الحدث', style: TextStyle(fontSize: 11, color: Colors.white54)),
            const SizedBox(height: 4),
            Image.memory(e.img,
                errorBuilder: (_, __, ___) => const Padding(
                    padding: EdgeInsets.all(20),
                    child: Icon(Icons.hearing_rounded, color: Colors.white38))),
            if (e.img2 != null) ...[
              const SizedBox(height: 10),
              const Text('بعد 3 ثوانٍ',
                  style: TextStyle(fontSize: 11, color: Colors.white54)),
              const SizedBox(height: 4),
              Image.memory(e.img2!),
            ],
            const SizedBox(height: 8),
            Text(fmtStamp(e.t), textDirection: TextDirection.ltr),
          ]),
        ),
        actions: [
          TextButton(
            onPressed: () => shareBytes(e.img, 'event.png'),
            child: const Text('مشاركة'),
          ),
          TextButton(
            onPressed: () async {
              try {
                if (!await Gal.hasAccess()) await Gal.requestAccess();
                await Gal.putImageBytes(e.img);
                _snack('تم الحفظ في الصور');
              } catch (_) {
                _snack('تعذّر الحفظ');
              }
            },
            child: const Text('حفظ في الصور'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
        ],
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
          if (_isConnected && !widget.screen && _cfg['son'] == true)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: LevelBar(level: _lvlN),
            ),
        ]),
      );

  Future<void> _connectScreen(String ip) async {
    final oldWs = _ws;
    _ws = null; // so the old socket's onDone is ignored
    oldWs?.close();
    _frame = null;
    final ws = _ws = await openWs(ip).timeout(const Duration(seconds: 5));
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
            if (_sw > 0 && _sh > 0 && _screenLand == null) {
              _screenLand = _sw > _sh;
              _screenOrient(_screenLand!);
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
          case 'role':
            setState(() => _role = '${d['role']}');
            break;
        }
      } else if (m is List<int>) {
        final b = m is Uint8List ? m : Uint8List.fromList(m);
        if (b.length < 8) return;
        final fw = (b[0] << 8) | b[1];
        final fh = (b[2] << 8) | b[3];
        if (fw != _sw || fh != _sh) {
          _sw = fw;
          _sh = fh;
          final land = fw > fh; // the other phone is in landscape (game/video)
          if (_screenLand != land) {
            _screenLand = land;
            _screenOrient(land);
          }
        }
        _pendingFrame = Uint8List.sublistView(b, 4);
        _decodeLoop(); // newest frame wins: no queue, minimal latency
      }
    }, onDone: () {
      if (mounted && !_denied && identical(_ws, ws)) {
        if (_isConnected) _alert('انقطع الاتصال بشاشة الهاتف — جاري إعادة الاتصال');
        _isConnected = false;
        _ws = null;
        _screenLand = null;
        _portrait();
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

  Future<void> _screenOrient(bool land) async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations(land
        ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
        : [DeviceOrientation.portraitUp]);
  }

  Offset _normClamp(Offset p, Size box) {
    if (_sw == 0 || _sh == 0) return Offset.zero;
    final sc = min(box.width / _sw, box.height / _sh);
    final dw = _sw * sc;
    final dh = _sh * sc;
    final ox = (box.width - dw) / 2;
    final oy = (box.height - dh) / 2;
    return Offset(((p.dx - ox) / dw).clamp(0.0, 1.0).toDouble(),
        ((p.dy - oy) / dh).clamp(0.0, 1.0).toDouble());
  }

  void _endTouch(PointerEvent e, Size box) {
    if (e.pointer != _ptr) return;
    _ptr = null;
    _touchPos.value = null;
    final n = _normClamp(e.localPosition, box);
    _send({'type': 'touch', 'a': 'u', 'x': n.dx, 'y': n.dy});
  }

  /// The other phone's screen. Raw pointer events: the remote stroke follows
  /// the finger immediately (down / move / up), no tap-vs-drag delay.
  Widget _screenArea() => LayoutBuilder(builder: (context, c) {
        final box = Size(c.maxWidth, c.maxHeight);
        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (e) {
            if (_ptr != null || _role == 'view') return;
            final n = _toNorm(e.localPosition, box);
            if (n == null) return;
            _ptr = e.pointer;
            _touchPos.value = e.localPosition;
            _send({'type': 'touch', 'a': 'd', 'x': n.dx, 'y': n.dy});
          },
          onPointerMove: (e) {
            if (e.pointer != _ptr) return;
            _touchPos.value = e.localPosition;
            final now = DateTime.now();
            if (now.difference(_lastMove).inMilliseconds < 8) return;
            _lastMove = now;
            final n = _normClamp(e.localPosition, box);
            _send({'type': 'touch', 'a': 'm', 'x': n.dx, 'y': n.dy});
          },
          onPointerUp: (e) => _endTouch(e, box),
          onPointerCancel: (e) => _endTouch(e, box),
          child: Stack(fit: StackFit.expand, children: [
            Container(color: Colors.black),
            ValueListenableBuilder<ui.Image?>(
              valueListenable: _uiImg,
              builder: (_, img, __) => img == null
                  ? const Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Icon(Icons.phone_android_rounded,
                            size: 40, color: Colors.white24),
                        SizedBox(height: 8),
                        Text('لا يوجد بث للشاشة',
                            style: TextStyle(color: Colors.white38)),
                      ]),
                    )
                  : RawImage(image: img, fit: BoxFit.contain),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: ValueListenableBuilder<Offset?>(
                  valueListenable: _touchPos,
                  builder: (_, p, __) => p == null
                      ? const SizedBox.shrink()
                      : CustomPaint(painter: _DotPainter(p)),
                ),
              ),
            ),
          ]),
        );
      });

  Future<void> _decodeLoop() async {
    if (_decoding) return;
    _decoding = true;
    try {
      while (_pendingFrame != null && mounted) {
        final b = _pendingFrame!;
        _pendingFrame = null;
        try {
          final codec = await ui.instantiateImageCodec(b);
          final fr = await codec.getNextFrame();
          codec.dispose();
          final old = _uiImg.value;
          _uiImg.value = fr.image;
          if (old != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
          }
        } catch (_) {}
      }
    } finally {
      _decoding = false;
    }
  }

  void _armBar() {
    _barTimer?.cancel();
    _barTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _barOn = false);
    });
  }

  void _toggleBar() {
    setState(() => _barOn = !_barOn);
    if (_barOn) _armBar();
  }

  Widget _sbtn(IconData i, VoidCallback f) => IconButton(
        icon: Icon(i, color: Colors.white70),
        onPressed: () {
          f();
          _armBar();
        },
      );

  /// Full-screen mirror: only a faint handle is visible; tap it to show the
  /// transparent buttons (they hide again after 4 s).
  Widget _screenFull() => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(children: [
          Positioned.fill(child: _screenArea()),
          Positioned(
            top: 8,
            right: 8,
            child: SafeArea(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleBar,
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: const BoxDecoration(
                    color: Color(0x22FFFFFF),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                      _barOn ? Icons.close_rounded : Icons.more_horiz_rounded,
                      size: 18,
                      color: Colors.white38),
                ),
              ),
            ),
          ),
          if (_barOn && _role != 'view')
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: SafeArea(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    decoration: BoxDecoration(
                      color: const Color(0x55000000),
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      _sbtn(Icons.arrow_back,
                          () => _send({'type': 'nav', 'action': 'back'})),
                      _sbtn(Icons.home_rounded,
                          () => _send({'type': 'nav', 'action': 'home'})),
                      _sbtn(Icons.apps_rounded,
                          () => _send({'type': 'nav', 'action': 'recents'})),
                      _sbtn(Icons.notifications_rounded,
                          () => _send({'type': 'nav', 'action': 'notifications'})),
                      _sbtn(Icons.logout_rounded, () => Navigator.pop(context)),
                    ]),
                  ),
                ),
              ),
            ),
        ]),
      );

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
    _lvlN.dispose();
    _touchPos.dispose();
    _uiImg.value?.dispose();
    _uiImg.dispose();
    _barTimer?.cancel();
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

  Widget _controls({required bool dark}) {
    if (_role != 'view') return _controlsAll(dark: dark);
    return Wrap(
      alignment: WrapAlignment.spaceEvenly,
      spacing: 6,
      runSpacing: 6,
      children: [
        CtlButton(
            icon: _muted ? Icons.volume_off : Icons.volume_up,
            label: 'الصوت',
            active: _muted,
            dark: dark,
            onTap: _toggleMute),
        CtlButton(
            icon: Icons.photo_camera_rounded,
            label: 'لقطة',
            dark: dark,
            onTap: _shot),
        CtlButton(
            icon: Icons.nightlight_round,
            label: 'ليلي',
            active: _night > 0,
            dark: dark,
            onTap: _tools),
        CtlButton(
            icon: Icons.video_library_rounded,
            label: 'التسجيلات',
            dark: dark,
            onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => LibraryPage(
                        ip: _ipCtl.text.trim(), pin: _pinCtl.text)))),
        CtlButton(
            icon: _wide ? Icons.fullscreen_exit : Icons.fullscreen,
            label: _wide ? 'تصغير' : 'عريض',
            dark: dark,
            onTap: () => _setWide(!_wide)),
      ],
    );
  }

  Widget _controlsAll({required bool dark}) => Wrap(
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
              icon: Icons.video_library_rounded,
              label: 'التسجيلات',
              dark: dark,
              onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => LibraryPage(
                          ip: _ipCtl.text.trim(), pin: _pinCtl.text)))),
          CtlButton(
              icon: Icons.security_rounded,
              label: 'الأمان',
              active: _cfg['on'] == true,
              dark: dark,
              onTap: _security),
          CtlButton(
              icon: _unread > 0
                  ? Icons.notifications_active_rounded
                  : Icons.notifications_none_rounded,
              label: _unread > 0 ? 'الأحداث ($_unread)' : 'الأحداث',
              dark: dark,
              onTap: _eventsSheet),
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
    if (widget.screen && _isConnected) return _screenFull();
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

  void _save() {
    saveSettings({'cams': _cams}).then((_) => refreshShortcuts());
  }

  Future<void> _add() async {
    final c = await showDialog<Map<String, dynamic>>(
        context: context, builder: (_) => const _AddCamDialog());
    if (c == null || !mounted) return;
    setState(() => _cams.add(c));
    _save();
  }

  Future<void> _menu(int i) async {
    final v = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: kSurface,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
              leading: const Icon(Icons.edit_rounded),
              title: const Text('تعديل الاسم واللون'),
              onTap: () => Navigator.pop(ctx, 'edit')),
          if (i > 0)
            ListTile(
                leading: const Icon(Icons.arrow_upward_rounded),
                title: const Text('تقديم'),
                onTap: () => Navigator.pop(ctx, 'up')),
          if (i < _cams.length - 1)
            ListTile(
                leading: const Icon(Icons.arrow_downward_rounded),
                title: const Text('تأخير'),
                onTap: () => Navigator.pop(ctx, 'down')),
          ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('حذف'),
              onTap: () => Navigator.pop(ctx, 'del')),
        ]),
      ),
    );
    if (v == null || !mounted) return;
    if (v == 'edit') {
      final c = await showDialog<Map<String, dynamic>>(
          context: context, builder: (_) => _AddCamDialog(initial: _cams[i]));
      if (c == null || !mounted) return;
      setState(() => _cams[i] = c);
    } else if (v == 'up') {
      setState(() {
        final x = _cams.removeAt(i);
        _cams.insert(i - 1, x);
      });
    } else if (v == 'down') {
      setState(() {
        final x = _cams.removeAt(i);
        _cams.insert(i + 1, x);
      });
    } else if (v == 'del') {
      setState(() => _cams.removeAt(i));
    }
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
                              onMenu: () => _menu(i),
                            ),
                  ],
                ),
              ),
      );
}

const List<int> kCamColors = [
  0xFF22D3EE,
  0xFF34D399,
  0xFFF472B6,
  0xFFFBBF24,
  0xFFA78BFA,
  0xFFF87171,
];

class _AddCamDialog extends StatefulWidget {
  const _AddCamDialog({this.initial});
  final Map<String, dynamic>? initial;
  @override
  State<_AddCamDialog> createState() => _AddCamDialogState();
}

class _AddCamDialogState extends State<_AddCamDialog> {
  final _name = TextEditingController();
  final _ip = TextEditingController();
  final _pin = TextEditingController();
  bool _scanning = false;
  List<String> _found = [];
  int _color = kCamColors[0];

  @override
  void initState() {
    super.initState();
    final i = widget.initial;
    if (i != null) {
      _name.text = '${i['name'] ?? ''}';
      _ip.text = '${i['ip'] ?? ''}';
      _pin.text = '${i['pin'] ?? ''}';
      _color = (i['color'] as int?) ?? kCamColors[0];
    }
  }

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
            Wrap(spacing: 8, children: [
              for (final c in kCamColors)
                GestureDetector(
                  onTap: () => setState(() => _color = c),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: Color(c),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: _color == c ? Colors.white : Colors.transparent,
                          width: 2.5),
                    ),
                  ),
                ),
            ]),
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
                'color': _color,
              });
            },
            child: Text(widget.initial == null ? 'إضافة' : 'حفظ'),
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
    required this.onMenu,
  });
  final Map<String, dynamic> cam;
  final VoidCallback onOpen;
  final VoidCallback onRemove;
  final VoidCallback onMenu;
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
  Uint8List? _last; // last picture seen from this camera
  Timer? _thumbTimer;

  String get _ip => '${widget.cam['ip']}';
  String get _pin => '${widget.cam['pin']}';
  Color get _col => Color((widget.cam['color'] as int?) ?? kCamColors[0]);

  @override
  void initState() {
    super.initState();
    thumbFile(_ip).then((f) async {
      if (await f.exists()) {
        final b = await f.readAsBytes();
        if (mounted) setState(() => _last = b);
      }
    });
    _thumbTimer = Timer.periodic(const Duration(seconds: 60), (_) => _saveLast());
    _r.initialize().then((_) => _connect());
  }

  Future<void> _saveLast() async {
    if (!_live) return;
    try {
      final tr = _r.srcObject?.getVideoTracks();
      if (tr == null || tr.isEmpty) return;
      final png = (await tr.first.captureFrame()).asUint8List();
      final th = await pngThumb(png, 360);
      if (th == null) return;
      await (await thumbFile(_ip)).writeAsBytes(th);
      kThumbRev.value++;
    } catch (_) {}
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
      final ws = _ws = await openWs(_ip).timeout(const Duration(seconds: 5));
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
    _thumbTimer?.cancel();
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
      onLongPress: widget.onMenu,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(15),
          border: Border.all(color: _col, width: 2),
        ),
        child: ClipRRect(
        borderRadius: BorderRadius.circular(13),
        child: Stack(fit: StackFit.expand, children: [
          Container(color: Colors.black),
          if (_last != null && !_live)
            Opacity(
              opacity: 0.45,
              child: Image.memory(_last!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox()),
            ),
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
                    color: _live ? _col : Colors.amber,
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
      ),
    );
  }
}

// ───────────────── Recordings / events library (served by the camera) ─────────────────
Future<File> thumbFile(String ip) async {
  final base = await getApplicationDocumentsDirectory();
  final d = Directory('${base.path}/thumbs');
  if (!await d.exists()) await d.create(recursive: true);
  return File('${d.path}/${ip.replaceAll(RegExp(r'[^0-9a-zA-Z.]'), '_')}.png');
}

/// Downscaled PNG of a captured frame (for thumbnails).
Future<Uint8List?> pngThumb(Uint8List png, int width) async {
  ui.Codec? codec;
  ui.Image? img;
  try {
    codec = await ui.instantiateImageCodec(png, targetWidth: width);
    img = (await codec.getNextFrame()).image;
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bd == null) return null;
    return bd.buffer.asUint8List(bd.offsetInBytes, bd.lengthInBytes);
  } catch (_) {
    return null;
  } finally {
    img?.dispose();
    codec?.dispose();
  }
}

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key, required this.ip, required this.pin});
  final String ip;
  final String pin;
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _err;
  final Map<String, Uint8List> _thumbs = {};
  final Map<String, double> _prog = {};
  List<Map<String, dynamic>> _tlDays = [];
  String _role = 'admin';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Uri _u(String path, [Map<String, String> q = const {}]) {
    final qp = {'pin': widget.pin, ...q};
    return kTls
        ? Uri.https('${widget.ip}:$kPort', path, qp)
        : Uri.http('${widget.ip}:$kPort', path, qp);
  }

  Future<HttpClientResponse> _get(HttpClient c, String path,
      [Map<String, String> q = const {}]) async {
    final req = await c.getUrl(_u(path, q));
    return req.close();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _err = null;
    });
    final c = tlsClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final res = await _get(c, '/lib/list');
      if (res.statusCode == 403) throw 'PIN غير صحيح';
      if (res.statusCode == 429) throw 'محاولات كثيرة — انتظر 5 دقائق';
      if (res.statusCode != 200) throw 'تعذّر جلب القائمة';
      final body = await res.transform(utf8.decoder).join();
      final l = (jsonDecode(body) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      l.sort((a, b) => (b['t'] as num).compareTo(a['t'] as num));
      _role = res.headers.value('x-role') ?? 'admin';
      try {
        final r2 = await _get(c, '/lib/tl');
        if (r2.statusCode == 200) {
          final b2 = await r2.transform(utf8.decoder).join();
          _tlDays = (jsonDecode(b2) as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList()
            ..sort((a, b) => '${b['d']}'.compareTo('${a['d']}'));
        } else {
          await r2.drain();
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _items = l;
        _loading = false;
      });
      _loadThumbs(l);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _err = e is String ? e : 'تعذّر الاتصال بالكاميرا';
        });
      }
    } finally {
      c.close(force: true);
    }
  }

  Future<void> _loadThumbs(List<Map<String, dynamic>> l) async {
    final c = tlsClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      for (final it in l) {
        if (!mounted) return;
        if (it['k'] != 'evt') continue;
        final n = '${it['n']}';
        if (_thumbs.containsKey(n)) continue;
        try {
          final res = await _get(c, '/lib/file', {'k': 'evt', 'n': n});
          if (res.statusCode != 200) continue;
          final b = BytesBuilder();
          await for (final chunk in res) {
            b.add(chunk);
          }
          if (mounted) setState(() => _thumbs[n] = b.toBytes());
        } catch (_) {}
      }
    } finally {
      c.close(force: true);
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  /// Download a recording to this phone and put it in Photos.
  Future<void> _download(Map<String, dynamic> it, {bool share = false}) async {
    final n = '${it['n']}';
    if (_prog.containsKey(n)) return;
    setState(() => _prog[n] = 0);
    final c = tlsClient()..connectionTimeout = const Duration(seconds: 5);
    File? f;
    try {
      final res = await _get(c, '/lib/file', {'k': 'rec', 'n': n});
      if (res.statusCode != 200) throw 'fail';
      final dir = await getTemporaryDirectory();
      f = File('${dir.path}/$n');
      final sink = f.openWrite();
      final total = res.contentLength > 0 ? res.contentLength : (it['s'] as num).toInt();
      var got = 0;
      await for (final chunk in res) {
        sink.add(chunk);
        got += chunk.length;
        if (mounted && total > 0) setState(() => _prog[n] = got / total);
      }
      await sink.flush();
      await sink.close();
      if (share) {
        await Share.shareXFiles([XFile(f.path)]);
      } else {
        if (!await Gal.hasAccess()) await Gal.requestAccess();
        await Gal.putVideo(f.path);
        _snack('تم تنزيل التسجيل وحفظه في الصور');
      }
    } catch (_) {
      _snack('تعذّر تنزيل التسجيل');
    } finally {
      c.close(force: true);
      try {
        await f?.delete();
      } catch (_) {}
      if (mounted) setState(() => _prog.remove(n));
    }
  }

  Future<void> _delete(Map<String, dynamic> it) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSurface,
        title: const Text('حذف من جهاز الكاميرا؟'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('إلغاء')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('حذف')),
        ],
      ),
    );
    if (ok != true) return;
    final c = tlsClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final res = await _get(c, '/lib/del', {'k': '${it['k']}', 'n': '${it['n']}'});
      await res.drain();
      if (mounted) {
        setState(() => _items.remove(it));
        if (it['k'] == 'tl') _load();
      }
    } catch (_) {
      _snack('تعذّر الحذف');
    } finally {
      c.close(force: true);
    }
  }

  String _size(num b) => b > 1048576
      ? '${(b / 1048576).toStringAsFixed(1)} MB'
      : '${(b / 1024).toStringAsFixed(0)} KB';

  String _evtKind(String n) => n.contains('_sound') ? 'صوت' : 'حركة';

  void _openEvt(Map<String, dynamic> it) {
    final b = _thumbs['${it['n']}'];
    if (b == null) return;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kSurface,
        contentPadding: const EdgeInsets.all(10),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Image.memory(b),
          const SizedBox(height: 8),
          Text(fmtStamp(DateTime.fromMillisecondsSinceEpoch((it['t'] as num).toInt())),
              textDirection: TextDirection.ltr),
        ]),
        actions: [
          TextButton(
            onPressed: () => shareBytes(b, 'event.png'),
            child: const Text('مشاركة'),
          ),
          TextButton(
            onPressed: () async {
              try {
                if (!await Gal.hasAccess()) await Gal.requestAccess();
                await Gal.putImageBytes(b);
                _snack('تم الحفظ في الصور');
              } catch (_) {
                _snack('تعذّر الحفظ');
              }
            },
            child: const Text('حفظ في الصور'),
          ),
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    final names = [for (final it in _items) if (it['k'] == 'evt') '${it['n']}'];
    final today = summarizeEvents(names, DateTime.now());
    final yest = summarizeEvents(names, DateTime.now().subtract(const Duration(days: 1)));
    if (names.isNotEmpty) {
      rows.add(Container(
        margin: const EdgeInsets.only(top: 12, bottom: 4),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('ملخص الأحداث',
              style: TextStyle(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(today.text('اليوم'),
              style: const TextStyle(fontSize: 12, color: Colors.white70, height: 1.6)),
          Text(yest.text('أمس'),
              style: const TextStyle(fontSize: 12, color: Colors.white54, height: 1.6)),
        ]),
      ));
    }
    for (final d in _tlDays) {
      rows.add(Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(children: [
          const Icon(Icons.slow_motion_video_rounded, color: kAccent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('تصوير زمني ${d['d']}',
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              Text('${d['n']} لقطة',
                  style: const TextStyle(fontSize: 11, color: Colors.white54)),
            ]),
          ),
          IconButton(
            icon: const Icon(Icons.play_circle_fill_rounded),
            onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (_) => TimelapsePage(
                        ip: widget.ip, pin: widget.pin, day: '${d['d']}'))),
          ),
          if (_role == 'admin')
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: () => _delete({'k': 'tl', 'n': d['d']}),
            ),
        ]),
      ));
    }
    String? day;
    for (final it in _items) {
      final t = DateTime.fromMillisecondsSinceEpoch((it['t'] as num).toInt());
      final d = '${t.year}-${two(t.month)}-${two(t.day)}';
      if (d != day) {
        day = d;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
          child: Text(d,
              textDirection: TextDirection.ltr,
              style: const TextStyle(
                  fontWeight: FontWeight.w800, color: Colors.white70)),
        ));
      }
      final n = '${it['n']}';
      final hm = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
      if (it['k'] == 'rec') {
        final p = _prog[n];
        rows.add(Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: kSurface,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(children: [
            const Icon(Icons.videocam_rounded, color: kAccent),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('تسجيل $hm',
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(_size(it['s'] as num),
                    style: const TextStyle(fontSize: 11, color: Colors.white54)),
                if (p != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: LinearProgressIndicator(value: p),
                  ),
              ]),
            ),
            IconButton(
              icon: const Icon(Icons.download_rounded),
              tooltip: 'تنزيل إلى الصور',
              onPressed: p != null ? null : () => _download(it),
            ),
            IconButton(
              icon: const Icon(Icons.share_rounded),
              tooltip: 'مشاركة',
              onPressed: p != null ? null : () => _download(it, share: true),
            ),
            if (_role == 'admin')
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () => _delete(it),
              ),
          ]),
        ));
      } else {
        final b = _thumbs[n];
        rows.add(Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: kSurface,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(children: [
            GestureDetector(
              onTap: () => _openEvt(it),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: SizedBox(
                  width: 96,
                  height: 60,
                  child: b == null
                      ? const Center(
                          child: Icon(Icons.image_outlined, color: Colors.white24))
                      : Image.memory(b,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(
                              Icons.hearing_rounded,
                              color: Colors.white38)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${_evtKind(n)} $hm',
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(fontWeight: FontWeight.w700)),
                Text('لقطة حدث',
                    style: const TextStyle(fontSize: 11, color: Colors.white54)),
              ]),
            ),
            if (_role == 'admin')
              IconButton(
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () => _delete(it),
              ),
          ]),
        ));
      }
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('تسجيلات وأحداث الكاميرا'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh_rounded), onPressed: _load),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _err != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_err!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70)),
                  ),
                )
              : _items.isEmpty
                  ? const Center(
                      child: Text('لا توجد تسجيلات أو أحداث',
                          style: TextStyle(color: Colors.white54)))
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                      children: rows),
    );
  }
}

// ───────────────── Time-lapse player (frames served by the camera) ─────────────────
class TimelapsePage extends StatefulWidget {
  const TimelapsePage(
      {super.key, required this.ip, required this.pin, required this.day});
  final String ip;
  final String pin;
  final String day;
  @override
  State<TimelapsePage> createState() => _TimelapsePageState();
}

class _TimelapsePageState extends State<TimelapsePage> {
  List<String> _names = [];
  final Map<int, Uint8List> _frames = {};
  int _i = 0;
  bool _play = true;
  int _fps = 8;
  Timer? _timer;
  bool _loading = true;
  String? _err;
  bool _dead = false;

  Uri _u(String path, Map<String, String> q) {
    final qp = {'pin': widget.pin, ...q};
    return kTls
        ? Uri.https('${widget.ip}:$kPort', path, qp)
        : Uri.http('${widget.ip}:$kPort', path, qp);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _dead = true;
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final c = tlsClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final req = await c.getUrl(_u('/lib/tl', {'d': widget.day}));
      final res = await req.close();
      if (res.statusCode != 200) throw 'fail';
      final body = await res.transform(utf8.decoder).join();
      _names = (jsonDecode(body) as List).map((e) => '$e').toList();
      if (mounted) setState(() => _loading = false);
      _startTimer();
      await _fetchAll(c);
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _err = 'تعذّر تحميل التصوير الزمني';
        });
      }
    } finally {
      c.close(force: true);
    }
  }

  Future<void> _fetchAll(HttpClient c) async {
    for (var i = 0; i < _names.length && !_dead; i++) {
      try {
        final req =
            await c.getUrl(_u('/lib/file', {'k': 'tl', 'n': _names[i]}));
        final res = await req.close();
        if (res.statusCode != 200) {
          await res.drain();
          continue;
        }
        final b = BytesBuilder();
        await for (final chunk in res) {
          b.add(chunk);
        }
        _frames[i] = b.takeBytes();
        if (mounted && i == _i) setState(() {});
      } catch (_) {}
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(milliseconds: 1000 ~/ _fps), (_) {
      if (!_play || _names.isEmpty || !mounted) return;
      final n = (_i + 1) % _names.length;
      if (_frames.containsKey(n)) setState(() => _i = n);
    });
  }

  String _label(int i) {
    if (i < 0 || i >= _names.length) return '';
    final m = RegExp(r'_(\d{2})-(\d{2})-\d{2}\.png$').firstMatch(_names[i]);
    return m == null ? '' : '${m.group(1)}:${m.group(2)}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text('تصوير زمني ${widget.day}')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _err != null
                ? Center(child: Text(_err!))
                : _names.isEmpty
                    ? const Center(child: Text('لا توجد لقطات'))
                    : Column(children: [
                        Expanded(
                          child: Container(
                            color: Colors.black,
                            width: double.infinity,
                            child: _frames[_i] == null
                                ? const Center(child: CircularProgressIndicator())
                                : Image.memory(_frames[_i]!,
                                    gaplessPlayback: true, fit: BoxFit.contain),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Column(children: [
                            Row(children: [
                              IconButton(
                                icon: Icon(_play
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded),
                                onPressed: () => setState(() => _play = !_play),
                              ),
                              Text(_label(_i),
                                  textDirection: TextDirection.ltr,
                                  style: const TextStyle(fontWeight: FontWeight.w700)),
                              const Spacer(),
                              Text('${_frames.length}/${_names.length}',
                                  style: const TextStyle(
                                      fontSize: 11, color: Colors.white54)),
                              const SizedBox(width: 10),
                              for (final f in const [4, 8, 16])
                                Padding(
                                  padding: const EdgeInsets.only(left: 6),
                                  child: ChoiceChip(
                                    label: Text('×${f ~/ 4}'),
                                    selected: _fps == f,
                                    onSelected: (_) {
                                      setState(() => _fps = f);
                                      _startTimer();
                                    },
                                  ),
                                ),
                            ]),
                            Slider(
                              value: _i.toDouble().clamp(0, (_names.length - 1).toDouble()),
                              min: 0,
                              max: (_names.length - 1).toDouble().clamp(1, 100000),
                              onChanged: (v) => setState(() {
                                _i = v.round();
                                _play = false;
                              }),
                            ),
                          ]),
                        ),
                      ]),
      );
}

// ───────────────── Language / accessibility / simple mode ─────────────────
const List<String> kLangs = ['ar', 'en', 'fr', 'tr', 'ur'];
String kLang = 'ar';
double kFontScale = 1.0;
bool kContrast = false;
bool kSpeak = false;
bool kSimple = false;
final ValueNotifier<int> kUiRev = ValueNotifier<int>(0);
bool get kRtl => kLang == 'ar' || kLang == 'ur';

String resolveLang(String? pref) {
  if (pref != null && kLangs.contains(pref)) return pref;
  final c = WidgetsBinding.instance.platformDispatcher.locale.languageCode;
  return kLangs.contains(c) ? c : 'en';
}

/// Applies language / font size / contrast / simple mode and rebuilds the app.
void applyUiPrefs(Map<String, dynamic> s) {
  final l = resolveLang(s['lang'] as String?);
  final fs = ((s['fontScale'] as num?) ?? 1.0).toDouble();
  final hc = s['contrast'] == true;
  final sm = s['simple'] == true;
  final changed = l != kLang || fs != kFontScale || hc != kContrast || sm != kSimple;
  kLang = l;
  kFontScale = fs;
  kContrast = hc;
  kSpeak = s['speak'] == true;
  kSimple = sm;
  if (changed) kUiRev.value++;
}

String tr(String s) {
  if (kLang == 'ar') return s;
  final l = kTr[s];
  if (l == null) return s;
  switch (kLang) {
    case 'en':
      return l[0];
    case 'fr':
      return l[1];
    case 'tr':
      return l[2];
    default:
      return l[3];
  }
}

class _UiScope extends InheritedWidget {
  const _UiScope({required this.rev, required super.child});
  final int rev;
  @override
  bool updateShouldNotify(_UiScope old) => old.rev != rev;
}

/// Drop-in replacement for Flutter's Text that translates known strings.
class Text extends StatelessWidget {
  const Text(
    this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.textDirection,
    this.maxLines,
    this.overflow,
  });
  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    context.dependOnInheritedWidgetOfExactType<_UiScope>();
    return w.Text(tr(data),
        style: style,
        textAlign: textAlign,
        textDirection: textDirection,
        maxLines: maxLines,
        overflow: overflow);
  }
}

/// Reads alerts aloud (accessibility).
class Speaker {
  static FlutterTts? _t;
  static const _loc = {
    'ar': 'ar-SA',
    'en': 'en-US',
    'fr': 'fr-FR',
    'tr': 'tr-TR',
    'ur': 'ur-PK',
  };
  static Future<void> say(String text) async {
    if (!kSpeak) return;
    try {
      _t ??= FlutterTts();
      await _t!.setLanguage(_loc[kLang] ?? 'ar-SA');
      await _t!.setSpeechRate(0.45);
      await _t!.speak(tr(text));
    } catch (_) {}
  }
}

/// Wraps the app: language scope, font size, high contrast, app lock.
Widget uiShell(BuildContext context, Widget? child) {
  final mq = MediaQuery.of(context);
  Widget c = LockGate(child: child ?? const SizedBox());
  if (kContrast) {
    c = ColorFiltered(
      colorFilter: const ColorFilter.matrix(<double>[
        1.35, 0, 0, 0, -22, //
        0, 1.35, 0, 0, -22, //
        0, 0, 1.35, 0, -22, //
        0, 0, 0, 1, 0,
      ]),
      child: c,
    );
  }
  return _UiScope(
    rev: kUiRev.value,
    child: Directionality(
      textDirection: kRtl ? TextDirection.rtl : TextDirection.ltr,
      child: MediaQuery(
        data: mq.copyWith(textScaler: TextScaler.linear(kFontScale)),
        child: c,
      ),
    ),
  );
}

// ───────────────── App lock (Face ID / fingerprint on iPhone, code elsewhere) ─────────────────
class LockGate extends StatefulWidget {
  const LockGate({super.key, required this.child});
  final Widget child;
  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> with WidgetsBindingObserver {
  bool _on = false;
  bool _locked = false;
  bool _checking = false;
  String _pin = '';
  String _entry = '';
  DateTime? _bg;
  bool _bad = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load(true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _load(bool cold) async {
    final s = await loadSettings();
    _on = s['appLock'] == true;
    _pin = '${s['appLockPin'] ?? ''}';
    if (_on && cold && mounted) {
      setState(() => _locked = true);
      _auth();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState st) {
    if (st == AppLifecycleState.paused) {
      _bg = DateTime.now();
    } else if (st == AppLifecycleState.resumed) {
      final b = _bg;
      _bg = null;
      _load(false).then((_) {
        if (_on &&
            b != null &&
            DateTime.now().difference(b).inSeconds > 30 &&
            !CameraPage.active &&
            mounted) {
          setState(() {
            _locked = true;
            _entry = '';
          });
          _auth();
        }
      });
    }
  }

  Future<void> _auth() async {
    if (_checking || !_locked || !Platform.isIOS) return;
    _checking = true;
    try {
      final la = LocalAuthentication();
      if (await la.isDeviceSupported()) {
        final ok = await la.authenticate(
          localizedReason: tr('افتح LAN Cam'),
          options: const AuthenticationOptions(stickyAuth: true),
        );
        if (ok && mounted) setState(() => _locked = false);
      } else if (_pin.isEmpty && mounted) {
        setState(() => _locked = false); // nothing to unlock with
      }
    } catch (_) {
    } finally {
      _checking = false;
    }
  }

  void _key(String k) {
    if (k.length != 1 || '0123456789'.indexOf(k) < 0) return;
    setState(() {
      _bad = false;
      _entry += k;
      if (_entry.length >= _pin.length) {
        if (_entry == _pin) {
          _locked = false;
          _entry = '';
        } else {
          _entry = '';
          _bad = true;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_locked || CameraPage.active) return widget.child;
    return Stack(children: [
      widget.child,
      Positioned.fill(
        child: Material(
          color: kBg,
          child: SafeArea(
            child: Column(children: [
              const Spacer(),
              const LogoMark(size: 84),
              const SizedBox(height: 16),
              const Text('التطبيق مقفل',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 18),
              if (Platform.isIOS)
                FilledButton.icon(
                  icon: const Icon(Icons.lock_open_rounded),
                  label: const Text('فتح بالبصمة أو الوجه'),
                  onPressed: _auth,
                ),
              if (_pin.isNotEmpty) ...[
                const SizedBox(height: 14),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  for (var i = 0; i < _pin.length; i++)
                    Container(
                      width: 14,
                      height: 14,
                      margin: const EdgeInsets.symmetric(horizontal: 5),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: i < _entry.length ? kAccent : Colors.white24,
                      ),
                    ),
                ]),
                if (_bad)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('الرمز غير صحيح',
                        style: TextStyle(color: kRed, fontSize: 12)),
                  ),
                const Spacer(),
                Keypad(
                  onKey: _key,
                  onBack: () => setState(() {
                    if (_entry.isNotEmpty) {
                      _entry = _entry.substring(0, _entry.length - 1);
                    }
                  }),
                ),
              ] else
                const Spacer(),
            ]),
          ),
        ),
      ),
    ]);
  }
}

/// Live microphone level of the camera (baby / sound monitoring).
class LevelBar extends StatelessWidget {
  const LevelBar({super.key, required this.level});
  final ValueListenable<double> level;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
        valueListenable: level,
        builder: (_, v, __) {
          final x = (v * 3).clamp(0.0, 1.0).toDouble();
          return Container(
            width: 120,
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0x99000000),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(children: [
              const Icon(Icons.graphic_eq_rounded, size: 13, color: Colors.white70),
              const SizedBox(width: 5),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: x,
                    minHeight: 6,
                    backgroundColor: Colors.white12,
                    color: x > 0.7 ? kRed : (x > 0.35 ? Colors.amber : kGreen),
                  ),
                ),
              ),
            ]),
          );
        },
      );
}



// ───────────────── Help hub + illustrated guides ─────────────────
class _GStep {
  const _GStep(this.icon, this.badge, this.title, this.text, {this.action});
  final IconData icon;
  final IconData badge;
  final String title;
  final String text;
  final String? action; // store | ip | web | diag
}

const Map<String, List<_GStep>> _kGuides = {
  'تثبيت الكاميرا في مكانها': [
    _GStep(Icons.location_on_rounded, Icons.arrow_upward_rounded,
        'اختر المكان', 'اختر مكاناً مرتفعاً يرى المنطقة كلها، وبعيداً عن الضوء المباشر.'),
    _GStep(Icons.phone_android_rounded, Icons.screen_rotation_rounded,
        'ثبّت الهاتف', 'ثبّت الهاتف أفقياً بحامل أو شريط لاصق، وتأكد أن العدسة غير محجوبة.'),
    _GStep(Icons.power_rounded, Icons.battery_charging_full_rounded,
        'وصّل الشاحن', 'ابقِ الهاتف على الشاحن، وفعّل "جاهزية دائمة" و"بدء الكاميرا عند الشحن".'),
    _GStep(Icons.wifi_rounded, Icons.signal_wifi_4_bar_rounded,
        'تأكد من الإشارة', 'قوة الواي فاي في المكان مهمة. جرّب البث وراقب مؤشر "اتصال قوي".'),
  ],
  'ضبط مناطق الكشف': [
    _GStep(Icons.security_rounded, Icons.touch_app_rounded,
        'افتح الأمان', 'من شاشة المشاهدة اضغط "الأمان" ثم "تحديد مناطق الكشف".'),
    _GStep(Icons.grid_on_rounded, Icons.brush_rounded,
        'لوّن الخانات', 'مرّر إصبعك على الخانات التي تريد تجاهلها، مثل شجرة تتحرك أو شارع.'),
    _GStep(Icons.visibility_off_rounded, Icons.visibility_rounded,
        'اختر الوضع', 'اختر "تجاهل المناطق" أو "مراقبة المناطق فقط" حسب حاجتك.'),
    _GStep(Icons.check_circle_rounded, Icons.done_all_rounded,
        'احفظ', 'اضغط "تم". جرّب بتحريك يدك أمام الكاميرا للتأكد.'),
  ],
  'فتح الأذونات': [
    _GStep(Icons.photo_camera_rounded, Icons.mic_rounded,
        'الكاميرا والميكروفون', 'اضغط "السماح" عند الطلب، وهما ضروريان للبث والصوت.'),
    _GStep(Icons.battery_saver_rounded, Icons.check_rounded,
        'استثناء البطارية', 'يمنع النظام من إغلاق التطبيق وهو يعمل في الخلفية.'),
    _GStep(Icons.layers_rounded, Icons.check_rounded,
        'الظهور فوق التطبيقات', 'يلزم لإيقاظ الكاميرا وهي مغلقة.'),
    _GStep(Icons.accessibility_new_rounded, Icons.touch_app_rounded,
        'إمكانية الوصول (اختياري)', 'للتحكم بشاشة الهاتف عن بعد. افتح فحص المشاكل لمتابعة الخطوات.',
        action: 'diag'),
  ],
  'المشاهدة من خارج البيت': [
    _GStep(Icons.download_rounded, Icons.apps_rounded,
        'ثبّت Tailscale', 'ثبّت تطبيق Tailscale المجاني على هاتف الكاميرا وهاتف المشاهد.',
        action: 'store'),
    _GStep(Icons.login_rounded, Icons.person_rounded,
        'سجّل بنفس الحساب', 'سجّل الدخول في التطبيقين بنفس الحساب، وفعّل الاتصال (VPN).'),
    _GStep(Icons.dns_rounded, Icons.numbers_rounded,
        'اعرف عنوان الكاميرا', 'على هاتف الكاميرا يظهر عنوان يبدأ بـ 100. بجانب كلمة VPN. استخدمه بدل عنوان الواي فاي.',
        action: 'ip'),
    _GStep(Icons.public_rounded, Icons.check_circle_rounded,
        'جرّب الاتصال', 'اكتب ذلك العنوان في المشاهد أو في "اختبار الاتصال". لا تفتح منافذ الراوتر.',
        action: 'diag'),
  ],
  'المشاهدة من المتصفح': [
    _GStep(Icons.language_rounded, Icons.link_rounded,
        'افتح الرابط', 'على أي جهاز على نفس الشبكة افتح الرابط المعروض على هاتف الكاميرا (ينتهي بـ /web).',
        action: 'web'),
    _GStep(Icons.shield_rounded, Icons.warning_amber_rounded,
        'اقبل التحذير', 'قد يعرض المتصفح تحذير شهادة لأن الاتصال محلي. اختر المتابعة.'),
    _GStep(Icons.pin_rounded, Icons.visibility_rounded,
        'اكتب الرمز', 'اكتب رمز المشاهدة فقط لتعرض البث بلا تحكم.'),
  ],
};

class HelpHubPage extends StatelessWidget {
  const HelpHubPage({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('ساعدني')),
        body: ListView(padding: const EdgeInsets.all(14), children: [
          ListTile(
            tileColor: kSurface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            leading: const Icon(Icons.health_and_safety_rounded, color: kAccent),
            title: const Text('لماذا لا يعمل؟'),
            subtitle: const Text('فحص سريع مع أزرار إصلاح',
                style: TextStyle(fontSize: 12, color: Colors.white54)),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const DiagPage())),
          ),
          const SizedBox(height: 10),
          ListTile(
            tileColor: kSurface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            leading: const Icon(Icons.rocket_launch_rounded, color: kAccent),
            title: const Text('الإعداد السريع'),
            onTap: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const SetupWizard())),
          ),
          const SizedBox(height: 14),
          const Text('أدلة مصورة',
              style: TextStyle(fontWeight: FontWeight.w800, color: Colors.white70)),
          const SizedBox(height: 8),
          for (final k in _kGuides.keys)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                tileColor: kSurface,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16)),
                leading: const Icon(Icons.play_circle_outline_rounded,
                    color: Color(0xFFFBBF24)),
                title: Text(k),
                trailing: const Icon(Icons.chevron_left_rounded),
                onTap: () => Navigator.push(context,
                    MaterialPageRoute(builder: (_) => GuidePage(name: k))),
              ),
            ),
        ]),
      );
}

class GuidePage extends StatefulWidget {
  const GuidePage({super.key, required this.name});
  final String name;
  @override
  State<GuidePage> createState() => _GuidePageState();
}

class _GuidePageState extends State<GuidePage> {
  final _pc = PageController();
  int _i = 0;
  String _tsIp = '';

  @override
  void initState() {
    super.initState();
    allIps().then((l) {
      for (final e in l) {
        if (e.value.startsWith('100.')) {
          if (mounted) setState(() => _tsIp = e.value);
        }
      }
    });
  }

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  Future<void> _open(String url) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Widget _action(_GStep st) {
    switch (st.action) {
      case 'store':
        return Wrap(spacing: 8, children: [
          FilledButton.tonal(
              onPressed: () =>
                  _open('https://apps.apple.com/app/tailscale/id1470499037'),
              child: const Text('App Store')),
          FilledButton.tonal(
              onPressed: () => _open(
                  'https://play.google.com/store/apps/details?id=com.tailscale.ipn'),
              child: const Text('Google Play')),
        ]);
      case 'ip':
        return Text(
            _tsIp.isEmpty
                ? 'لم يُكتشف Tailscale على هذا الهاتف بعد'
                : 'عنوان Tailscale لهذا الهاتف: $_tsIp',
            textDirection: TextDirection.ltr,
            style: TextStyle(color: _tsIp.isEmpty ? Colors.white54 : kGreen));
      case 'diag':
        return FilledButton.tonal(
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => const DiagPage())),
            child: const Text('لماذا لا يعمل؟'));
      case 'web':
        return Text('${kTls ? 'https' : 'http'}://عنوان-الكاميرا:$kPort/web',
            textDirection: TextDirection.ltr,
            style: const TextStyle(color: kAccent));
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final steps = _kGuides[widget.name] ?? const <_GStep>[];
    return Scaffold(
      appBar: AppBar(title: Text(widget.name)),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: PageView.builder(
              controller: _pc,
              itemCount: steps.length,
              onPageChanged: (v) => setState(() => _i = v),
              itemBuilder: (_, i) {
                final st = steps[i];
                return Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    TweenAnimationBuilder<double>(
                      key: ValueKey('g$i'),
                      tween: Tween(begin: 0.85, end: 1.0),
                      duration: const Duration(milliseconds: 700),
                      curve: Curves.elasticOut,
                      builder: (_, v, child) =>
                          Transform.scale(scale: v, child: child),
                      child: SizedBox(
                        width: 190,
                        height: 190,
                        child: Stack(alignment: Alignment.center, children: [
                          Container(
                            decoration: const BoxDecoration(
                                color: Color(0x2622D3EE), shape: BoxShape.circle),
                          ),
                          Icon(st.icon, size: 92, color: kAccent),
                          Positioned(
                            right: 22,
                            bottom: 22,
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              decoration: const BoxDecoration(
                                  color: kSurface2, shape: BoxShape.circle),
                              child: Icon(st.badge,
                                  size: 28, color: const Color(0xFFFBBF24)),
                            ),
                          ),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Text(st.title,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 10),
                    Text(st.text,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 15, color: Colors.white70, height: 1.7)),
                    const SizedBox(height: 16),
                    _action(st),
                  ]),
                );
              },
            ),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            for (var i = 0; i < steps.length; i++)
              Container(
                width: i == _i ? 22 : 8,
                height: 8,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  color: i == _i ? kAccent : Colors.white24,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
          ]),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              if (_i > 0)
                TextButton(
                    onPressed: () => _pc.previousPage(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut),
                    child: const Text('السابق')),
              const Spacer(),
              FilledButton(
                onPressed: () {
                  if (_i + 1 >= steps.length) {
                    Navigator.pop(context);
                  } else {
                    _pc.nextPage(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut);
                  }
                },
                child: Text(_i + 1 >= steps.length ? 'تم' : 'التالي'),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ───────────────── Access log (who watched, when) ─────────────────
class AccessLogPage extends StatefulWidget {
  const AccessLogPage({super.key, required this.ip, required this.pin});
  final String ip;
  final String pin;
  @override
  State<AccessLogPage> createState() => _AccessLogPageState();
}

class _AccessLogPageState extends State<AccessLogPage> {
  List<Map<String, dynamic>> _l = [];
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final c = tlsClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final qp = {'pin': widget.pin};
      final u = kTls
          ? Uri.https('${widget.ip}:$kPort', '/lib/log', qp)
          : Uri.http('${widget.ip}:$kPort', '/lib/log', qp);
      final res = await (await c.getUrl(u)).close();
      if (res.statusCode == 403) throw 'سجل الدخول لصاحب الرمز الأساسي فقط';
      if (res.statusCode != 200) throw 'تعذّر جلب القائمة';
      final body = await res.transform(utf8.decoder).join();
      _l = (jsonDecode(body) as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _err = e is String ? e : 'تعذّر الاتصال بالكاميرا';
        });
      }
    } finally {
      c.close(force: true);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('سجل الدخول')),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _err != null
                ? Center(child: Text(_err!))
                : _l.isEmpty
                    ? const Center(child: Text('لا توجد أحداث بعد'))
                    : ListView(padding: const EdgeInsets.all(12), children: [
                        for (final e in _l)
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: kSurface,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Row(children: [
                              Icon(
                                  e['role'] == 'admin'
                                      ? Icons.admin_panel_settings_rounded
                                      : Icons.visibility_rounded,
                                  color: e['role'] == 'admin' ? kAccent : Colors.white54),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                          fmtStamp(DateTime.fromMillisecondsSinceEpoch(
                                              (e['t'] as num).toInt())),
                                          textDirection: TextDirection.ltr,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.w700)),
                                      Text('${e['ip']}',
                                          textDirection: TextDirection.ltr,
                                          style: const TextStyle(
                                              fontSize: 12, color: Colors.white54)),
                                    ]),
                              ),
                              Text(e['role'] == 'admin' ? 'تحكم كامل' : 'مشاهدة فقط',
                                  style: const TextStyle(fontSize: 12)),
                            ]),
                          ),
                      ]),
      );
}

/// Scans a pairing QR, saves the camera in the list, returns its data.
Future<Map<String, dynamic>?> addCamFromQr(BuildContext context) async {
  final v = await Navigator.push<String>(
      context, MaterialPageRoute(builder: (_) => const QrScanPage()));
  if (v == null) return null;
  final p = v.split('|');
  if (p.length < 4) return null;
  final s = await loadSettings();
  final l = <Map<String, dynamic>>[
    for (final c in ((s['cams'] as List?) ?? const []))
      Map<String, dynamic>.from(c as Map),
  ];
  final existing = l.indexWhere((c) => c['ip'] == p[1]);
  final cam = <String, dynamic>{
    'name': existing >= 0 ? l[existing]['name'] : 'كاميرا ${l.length + 1}',
    'ip': p[1],
    'pin': p[3],
    'color': existing >= 0
        ? l[existing]['color']
        : kCamColors[l.length % kCamColors.length],
  };
  if (existing >= 0) {
    l[existing] = cam;
  } else if (l.length < 4) {
    l.add(cam);
  }
  await saveSettings({'cams': l, 'ip': p[1], 'pin': p[3]});
  refreshShortcuts();
  return cam;
}

/// Browser viewer served by the camera at /web (no app needed).
const String kWebPage = r'''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>LAN Cam</title>
<style>
body{margin:0;background:#0b1220;color:#e6edf3;font:16px system-ui,sans-serif;text-align:center}
#login{padding:60px 20px}
input{font-size:22px;padding:12px;border-radius:12px;border:0;width:170px;text-align:center;letter-spacing:6px}
button{font-size:16px;padding:12px 20px;border-radius:12px;border:0;background:#22d3ee;color:#04202a;margin:6px;cursor:pointer}
video{width:100%;max-height:82vh;background:#000}
#st{font-size:12px;color:#9aa4b2;padding:6px}
</style></head><body>
<div id="login">
<h2>LAN Cam</h2>
<p id="t1"></p>
<input id="pin" inputmode="numeric" maxlength="6" placeholder="PIN"><br><br>
<button id="go"></button>
<p id="msg" style="color:#fbbf24"></p>
</div>
<div id="view" hidden>
<video id="v" autoplay playsinline muted></video>
<div>
<button id="mu"></button><button id="fs"></button><button id="sn"></button>
</div>
<div id="st"></div>
</div>
<script>
var ar=(navigator.language||'en').indexOf('ar')===0;
var L=ar?{t1:'اكتب رمز المشاهدة',go:'مشاهدة',mu:'الصوت',fs:'ملء الشاشة',sn:'لقطة',bad:'PIN غير صحيح',lock:'محاولات كثيرة، انتظر',conn:'جاري الاتصال...',lost:'انقطع الاتصال، إعادة المحاولة...'}
:{t1:'Enter the viewing code',go:'Watch',mu:'Sound',fs:'Fullscreen',sn:'Snapshot',bad:'Wrong PIN',lock:'Too many attempts, wait',conn:'Connecting...',lost:'Disconnected, retrying...'};
if(ar)document.documentElement.dir='rtl';
function $(i){return document.getElementById(i)}
$('t1').textContent=L.t1;$('go').textContent=L.go;$('mu').textContent=L.mu;$('fs').textContent=L.fs;$('sn').textContent=L.sn;
var pc=null,ws=null,live=false,pin='',stop=false;
$('go').onclick=function(){pin=$('pin').value.trim();if(pin){stop=false;start();}};
$('mu').onclick=function(){$('v').muted=!$('v').muted;};
$('fs').onclick=function(){var v=$('v');(v.requestFullscreen||v.webkitEnterFullscreen||function(){}).call(v);};
$('sn').onclick=function(){var v=$('v'),c=document.createElement('canvas');c.width=v.videoWidth;c.height=v.videoHeight;c.getContext('2d').drawImage(v,0,0);var a=document.createElement('a');a.href=c.toDataURL('image/png');a.download='lancam.png';a.click();};
function retry(){if(stop)return;live=false;$('st').textContent=L.lost;setTimeout(start,3000);}
async function start(){
 try{if(ws)ws.close();if(pc)pc.close();}catch(e){}
 $('msg').textContent=L.conn;
 ws=new WebSocket((location.protocol==='https:'?'wss://':'ws://')+location.host);
 pc=new RTCPeerConnection({iceServers:[]});
 pc.addTransceiver('video',{direction:'recvonly'});
 pc.addTransceiver('audio',{direction:'recvonly'});
 pc.ontrack=function(e){if(e.track.kind==='video'){$('v').srcObject=e.streams[0];$('login').hidden=true;$('view').hidden=false;}};
 pc.onconnectionstatechange=function(){var s=pc.connectionState;if(s==='connected'){live=true;$('st').textContent='LIVE';}else if(s==='failed'||s==='disconnected'||s==='closed'){retry();}};
 ws.onmessage=async function(m){
  var d=JSON.parse(m.data);
  if(d.type==='answer'){await pc.setRemoteDescription({type:'answer',sdp:d.sdp});}
  else if(d.type==='denied'){stop=true;$('login').hidden=false;$('view').hidden=true;$('msg').textContent=L.bad;ws.close();}
  else if(d.type==='locked'){stop=true;$('login').hidden=false;$('view').hidden=true;$('msg').textContent=L.lock;ws.close();}
  else if(d.type==='health'&&live){var b=d.bat!=null?(' | '+d.bat+'%'+(d.chg?' ⚡':'')):'';$('st').textContent='LIVE'+b;}
 };
 ws.onclose=function(){if(!stop&&live)retry();};
 await new Promise(function(r){ws.onopen=r;});
 var offer=await pc.createOffer();await pc.setLocalDescription(offer);
 await new Promise(function(r){if(pc.iceGatheringState==='complete')r();else{pc.onicegatheringstatechange=function(){if(pc.iceGatheringState==='complete')r();};setTimeout(r,3000);}});
 ws.send(JSON.stringify({type:'offer',sdp:pc.localDescription.sdp,pin:pin}));
}
</script></body></html>''';

const Map<String, List<String>> kTr = {
  'الشبكة المحلية (واي فاي)': ['Local network (Wi‑Fi)', 'Réseau local (Wi‑Fi)', 'Yerel ağ (Wi‑Fi)', 'مقامی نیٹ ورک (وائی فائی)'],
  'غير متصل بشبكة. اتصل بالواي فاي نفسه على الهاتفين.': ['Not connected. Join the same Wi‑Fi on both phones.', 'Non connecté. Rejoignez le même Wi‑Fi sur les deux téléphones.', 'Bağlı değil. İki telefonda da aynı Wi‑Fi\'a bağlanın.', 'نیٹ ورک سے منسلک نہیں۔ دونوں فونز پر ایک ہی وائی فائی سے جڑیں۔'],
  'إذن الكاميرا': ['Camera permission', 'Autorisation de la caméra', 'Kamera izni', 'کیمرے کی اجازت'],
  'مسموح': ['Allowed', 'Autorisé', 'İzin verildi', 'اجازت ہے'],
  'غير مسموح (مطلوب لجهاز الكاميرا)': ['Not allowed (needed on the camera phone)', 'Refusé (requis sur le téléphone caméra)', 'İzin yok (kamera telefonunda gerekli)', 'اجازت نہیں (کیمرہ فون پر ضروری)'],
  'السماح': ['Allow', 'Autoriser', 'İzin ver', 'اجازت دیں'],
  'إذن الميكروفون': ['Microphone permission', 'Autorisation du micro', 'Mikrofon izni', 'مائیکروفون کی اجازت'],
  'غير مسموح (الصوت لن يعمل)': ['Not allowed (no sound)', 'Refusé (pas de son)', 'İzin yok (ses çalışmaz)', 'اجازت نہیں (آواز نہیں آئے گی)'],
  'الخدمة في الخلفية': ['Background service', 'Service en arrière-plan', 'Arka plan hizmeti', 'بیک گراؤنڈ سروس'],
  'تعمل': ['Running', 'En cours', 'Çalışıyor', 'چل رہی ہے'],
  'متوقفة. فعّل "جاهزية دائمة" في وضع الكاميرا.': ['Stopped. Turn on "Always ready" in camera mode.', 'Arrêté. Activez « Toujours prêt » en mode caméra.', 'Durdu. Kamera modunda "Her zaman hazır"ı açın.', 'بند ہے۔ کیمرہ موڈ میں "ہمیشہ تیار" آن کریں۔'],
  'يستمع': ['Listening', 'À l\'écoute', 'Dinliyor', 'سن رہا ہے'],
  'لا يستمع (الجاهزية الدائمة مطفأة)': ['Not listening (Always ready is off)', 'Pas d\'écoute (Toujours prêt désactivé)', 'Dinlemiyor (Her zaman hazır kapalı)', 'نہیں سن رہا (ہمیشہ تیار بند ہے)'],
  'استثناء توفير البطارية': ['Battery optimisation exemption', 'Exemption d\'économie de batterie', 'Pil tasarrufu muafiyeti', 'بیٹری سیور سے استثنا'],
  'مستثنى': ['Exempt', 'Exempté', 'Muaf', 'مستثنیٰ'],
  'النظام قد يقتل التطبيق في الخلفية': ['The system may close the app in the background', 'Le système peut fermer l\'app en arrière-plan', 'Sistem uygulamayı arka planda kapatabilir', 'سسٹم ایپ کو بیک گراؤنڈ میں بند کر سکتا ہے'],
  'استثناء': ['Exempt', 'Exempter', 'Muaf tut', 'استثنا دیں'],
  'الظهور فوق التطبيقات': ['Display over other apps', 'Affichage par-dessus les autres apps', 'Diğer uygulamaların üzerinde göster', 'دوسری ایپس کے اوپر دکھائیں'],
  'مطلوب لإيقاظ الكاميرا وهي مغلقة': ['Needed to wake the camera when it is closed', 'Nécessaire pour réveiller la caméra fermée', 'Kapalıyken kamerayı uyandırmak için gerekli', 'بند کیمرے کو جگانے کے لیے ضروری'],
  'التحكم في الشاشة (إمكانية الوصول)': ['Screen control (Accessibility)', 'Contrôle de l\'écran (Accessibilité)', 'Ekran kontrolü (Erişilebilirlik)', 'اسکرین کنٹرول (ایکسیسبیلٹی)'],
  'مفعّل': ['On', 'Activé', 'Açık', 'فعال'],
  'فتح': ['Open', 'Ouvrir', 'Aç', 'کھولیں'],
  'تشفير TLS': ['TLS encryption', 'Chiffrement TLS', 'TLS şifreleme', 'TLS خفیہ کاری'],
  'غير مضمّن في هذا الإصدار (الاتصال غير مشفّر)': ['Not included in this version (connection is not encrypted)', 'Non inclus dans cette version (connexion non chiffrée)', 'Bu sürümde yok (bağlantı şifresiz)', 'اس ورژن میں شامل نہیں (کنکشن غیر خفیہ ہے)'],
  'إشعارات خارجية (تيليغرام / ntfy)': ['External notifications (Telegram / ntfy)', 'Notifications externes (Telegram / ntfy)', 'Harici bildirimler (Telegram / ntfy)', 'بیرونی اطلاعات (ٹیلیگرام / ntfy)'],
  'مُعدّة والإنترنت متاح': ['Set up and internet is available', 'Configuré et Internet disponible', 'Kurulu ve internet var', 'ترتیب شدہ اور انٹرنیٹ دستیاب'],
  'مُعدّة لكن لا يوجد إنترنت الآن': ['Set up but no internet right now', 'Configuré mais pas d\'Internet', 'Kurulu ama şu an internet yok', 'ترتیب شدہ مگر ابھی انٹرنیٹ نہیں'],
  'غير مُعدّة (الإعدادات ← إشعارات خارجية)': ['Not set up (Settings → External notifications)', 'Non configuré (Réglages → Notifications externes)', 'Kurulu değil (Ayarlar → Harici bildirimler)', 'ترتیب نہیں دی گئی (سیٹنگز ← بیرونی اطلاعات)'],
  'الكاميرا تعمل وتستقبل': ['The camera is running and receiving', 'La caméra fonctionne et reçoit', 'Kamera çalışıyor ve bağlantı kabul ediyor', 'کیمرہ چل رہا ہے اور کنکشن لے رہا ہے'],
  'لا يوجد رد: الكاميرا مغلقة أو العنوان خطأ أو شبكة مختلفة': ['No reply: camera is off, wrong address, or a different network', 'Pas de réponse : caméra éteinte, mauvaise adresse ou autre réseau', 'Yanıt yok: kamera kapalı, adres yanlış veya farklı ağ', 'کوئی جواب نہیں: کیمرہ بند، غلط ایڈریس یا مختلف نیٹ ورک'],
  'الجاهزية الدائمة تعمل (يمكن إيقاظها)': ['Always ready is working (it can be woken)', 'Toujours prêt actif (peut être réveillée)', 'Her zaman hazır çalışıyor (uyandırılabilir)', 'ہمیشہ تیار فعال ہے (جگایا جا سکتا ہے)'],
  'غير مفعّل (غير مطلوب والكاميرا شغّالة)': ['Off (not needed, the camera is running)', 'Désactivé (inutile, la caméra tourne)', 'Kapalı (gerekmez, kamera çalışıyor)', 'بند (ضرورت نہیں، کیمرہ چل رہا ہے)'],
  'الجاهزية الدائمة غير مفعّلة على الكاميرا': ['Always ready is off on the camera', 'Toujours prêt désactivé sur la caméra', 'Kamerada Her zaman hazır kapalı', 'کیمرے پر ہمیشہ تیار بند ہے'],
  'إصلاح': ['Fix', 'Réparer', 'Düzelt', 'ٹھیک کریں'],
  'لماذا لا يعمل؟': ['Why isn\'t it working?', 'Pourquoi ça ne marche pas ?', 'Neden çalışmıyor?', 'یہ کیوں کام نہیں کر رہا؟'],
  'هذا الهاتف': ['This phone', 'Ce téléphone', 'Bu telefon', 'یہ فون'],
  'اختبار الاتصال بكاميرا': ['Test connection to a camera', 'Tester la connexion à une caméra', 'Bir kameraya bağlantıyı test et', 'کیمرے سے کنکشن کا ٹیسٹ'],
  'IP الكاميرا': ['Camera IP', 'IP de la caméra', 'Kamera IP', 'کیمرے کا IP'],
  'فحص': ['Check', 'Tester', 'Kontrol', 'جانچیں'],
  'ما دور هذا الهاتف؟': ['What is this phone\'s role?', 'Quel est le rôle de ce téléphone ?', 'Bu telefonun rolü nedir?', 'اس فون کا کردار کیا ہے؟'],
  'كاميرا': ['Camera', 'Caméra', 'Kamera', 'کیمرہ'],
  'يبقى في مكانه ويبث': ['Stays in place and streams', 'Reste en place et diffuse', 'Yerinde durur ve yayın yapar', 'اپنی جگہ رہ کر نشر کرتا ہے'],
  'مشاهد': ['Viewer', 'Spectateur', 'İzleyici', 'ناظر'],
  'أشاهد به الكاميرا وأتحكم': ['Watch the camera and control it', 'Regarder la caméra et la contrôler', 'Kamerayı izle ve kontrol et', 'کیمرہ دیکھیں اور کنٹرول کریں'],
  'الأذونات': ['Permissions', 'Autorisations', 'İzinler', 'اجازتیں'],
  'الكاميرا': ['Camera', 'Caméra', 'Kamera', 'کیمرہ'],
  'الميكروفون': ['Microphone', 'Micro', 'Mikrofon', 'مائیکروفون'],
  'العمل في الخلفية': ['Background operation', 'Fonctionnement en arrière-plan', 'Arka planda çalışma', 'بیک گراؤنڈ میں کام'],
  'كي تبقى الكاميرا تعمل وتُوقَظ وهي مغلقة': ['So the camera keeps running and can be woken when closed', 'Pour que la caméra reste active et puisse être réveillée', 'Kameranın çalışmaya devam etmesi ve kapalıyken uyandırılabilmesi için', 'تاکہ کیمرہ چلتا رہے اور بند ہونے پر جگایا جا سکے'],
  'التحكم في الشاشة (اختياري)': ['Screen control (optional)', 'Contrôle de l\'écran (facultatif)', 'Ekran kontrolü (isteğe bağlı)', 'اسکرین کنٹرول (اختیاری)'],
  'إشعارات وأنت بعيد (اختياري)': ['Alerts when you\'re away (optional)', 'Alertes à distance (facultatif)', 'Uzaktayken bildirimler (isteğe bağlı)', 'دور ہونے پر اطلاعات (اختیاری)'],
  'إعداد الإشعارات': ['Set up alerts', 'Configurer les alertes', 'Bildirimleri kur', 'اطلاعات ترتیب دیں'],
  'اربط جهاز المشاهدة': ['Pair the viewer device', 'Associer l\'appareil spectateur', 'İzleyici cihazı eşleştir', 'ناظر ڈیوائس جوڑیں'],
  'تأكد أنك متصل بالواي فاي': ['Make sure you\'re on Wi‑Fi', 'Vérifiez que vous êtes en Wi‑Fi', 'Wi‑Fi\'a bağlı olduğunuzdan emin olun', 'یقینی بنائیں کہ آپ وائی فائی پر ہیں'],
  'على هاتف المشاهد: اختر "مشاهد" ثم امسح هذا الرمز.': ['On the viewer phone: choose "Viewer", then scan this code.', 'Sur le téléphone spectateur : choisissez « Spectateur » puis scannez ce code.', 'İzleyici telefonda "İzleyici"yi seçip bu kodu tarayın.', 'ناظر فون پر "ناظر" چنیں پھر یہ کوڈ اسکین کریں۔'],
  'اربط الكاميرا': ['Pair the camera', 'Associer la caméra', 'Kamerayı eşleştir', 'کیمرہ جوڑیں'],
  'على هاتف الكاميرا افتح "وضع الكاميرا" ثم "عرض رمز QR للربط"، وامسحه هنا.': ['On the camera phone open "Camera mode", then "Show QR code to pair", and scan it here.', 'Sur le téléphone caméra, ouvrez « Mode caméra » puis « Afficher le code QR », et scannez-le ici.', 'Kamera telefonunda "Kamera modu"nu, sonra "QR kodunu göster"i açıp burada tarayın.', 'کیمرہ فون پر "کیمرہ موڈ" پھر "جوڑنے کا QR کوڈ دکھائیں" کھولیں اور یہاں اسکین کریں۔'],
  'مسح الرمز': ['Scan code', 'Scanner le code', 'Kodu tara', 'کوڈ اسکین کریں'],
  'الإعداد السريع': ['Quick setup', 'Configuration rapide', 'Hızlı kurulum', 'فوری سیٹ اپ'],
  'تخطي': ['Skip', 'Passer', 'Atla', 'چھوڑیں'],
  'السابق': ['Back', 'Précédent', 'Geri', 'پچھلا'],
  'تم': ['Done', 'Terminé', 'Tamam', 'ہو گیا'],
  'التالي': ['Next', 'Suivant', 'İleri', 'اگلا'],
  'عالية': ['High', 'Élevée', 'Yüksek', 'اعلیٰ'],
  'جيدة': ['Good', 'Bonne', 'İyi', 'اچھی'],
  'متوسطة': ['Medium', 'Moyenne', 'Orta', 'درمیانی'],
  'منخفضة': ['Low', 'Faible', 'Düşük', 'کم'],
  'دنيا': ['Lowest', 'Minimale', 'En düşük', 'کم ترین'],
  'اتصال قوي': ['Strong link', 'Lien fort', 'Güçlü bağlantı', 'مضبوط کنکشن'],
  'متوسط': ['Medium', 'Moyen', 'Orta', 'درمیانی'],
  'ضعيف': ['Weak', 'Faible', 'Zayıf', 'کمزور'],
  'امسح رمز QR من شاشة الكاميرا': ['Scan the QR code from the camera screen', 'Scannez le code QR de l\'écran de la caméra', 'Kamera ekranındaki QR kodunu tarayın', 'کیمرے کی اسکرین سے QR کوڈ اسکین کریں'],
  'على جهاز الكاميرا اضغط "عرض رمز QR"': ['On the camera device tap "Show QR code"', 'Sur la caméra, touchez « Afficher le code QR »', 'Kamera cihazında "QR kodunu göster"e dokunun', 'کیمرہ ڈیوائس پر "QR کوڈ دکھائیں" دبائیں'],
  'تم النسخ': ['Copied', 'Copié', 'Kopyalandı', 'کاپی ہو گیا'],
  'مراقبة خاصة عبر شبكتك المحلية': ['Private monitoring over your local network', 'Surveillance privée sur votre réseau local', 'Yerel ağınız üzerinden özel izleme', 'آپ کے مقامی نیٹ ورک پر نجی نگرانی'],
  'وضع الكاميرا': ['Camera mode', 'Mode caméra', 'Kamera modu', 'کیمرہ موڈ'],
  'حوّل هذا الهاتف إلى كاميرا مراقبة': ['Turn this phone into a security camera', 'Transformez ce téléphone en caméra de surveillance', 'Bu telefonu güvenlik kamerasına çevirin', 'اس فون کو نگرانی کیمرہ بنائیں'],
  'وضع المشاهدة': ['Viewer mode', 'Mode spectateur', 'İzleyici modu', 'ناظر موڈ'],
  'شاهد البث واتحكم بالكاميرا عن بعد': ['Watch the stream and control the camera remotely', 'Regardez le flux et contrôlez la caméra à distance', 'Yayını izleyin, kamerayı uzaktan kontrol edin', 'سٹریم دیکھیں اور کیمرہ دور سے کنٹرول کریں'],
  'عدة كاميرات': ['Multiple cameras', 'Plusieurs caméras', 'Birden çok kamera', 'متعدد کیمرے'],
  'شاهد حتى 4 كاميرات معاً في شبكة 2×2': ['Watch up to 4 cameras together in a 2×2 grid', 'Jusqu\'à 4 caméras ensemble en grille 2×2', '2×2 ızgarada 4 kameraya kadar birlikte izleyin', '2×2 گرڈ میں 4 کیمرے تک ایک ساتھ دیکھیں'],
  'شاشة الهاتف': ['Phone screen', 'Écran du téléphone', 'Telefon ekranı', 'فون اسکرین'],
  'اعرض شاشة هاتف آخر وتحكم به عن بعد': ['Show another phone\'s screen and control it remotely', 'Affichez l\'écran d\'un autre téléphone et contrôlez-le', 'Başka bir telefonun ekranını gösterin ve uzaktan kontrol edin', 'دوسرے فون کی اسکرین دیکھیں اور دور سے کنٹرول کریں'],
  'إعدادات البث': ['Stream settings', 'Réglages du flux', 'Yayın ayarları', 'سٹریم سیٹنگز'],
  'الدقة، الإطارات، معدل البيانات وغيرها': ['Resolution, frame rate, bitrate and more', 'Résolution, images/s, débit et plus', 'Çözünürlük, kare hızı, bit hızı ve daha fazlası', 'ریزولوشن، فریم ریٹ، بٹ ریٹ اور مزید'],
  'بث مباشر': ['Live stream', 'Flux en direct', 'Canlı yayın', 'لائیو سٹریم'],
  'صوت ثنائي الاتجاه': ['Two‑way audio', 'Audio bidirectionnel', 'Çift yönlü ses', 'دو طرفہ آواز'],
  'تسجيل': ['Record', 'Enregistrer', 'Kayıt', 'ریکارڈ'],
  'رمز حماية PIN': ['PIN protection', 'Protection par PIN', 'PIN koruması', 'PIN تحفظ'],
  'ربط QR': ['QR pairing', 'Association QR', 'QR eşleştirme', 'QR جوڑنا'],
  'رؤية ليلية': ['Night view', 'Vision nocturne', 'Gece görüşü', 'رات کا منظر'],
  'إعادة اتصال تلقائية': ['Auto reconnect', 'Reconnexion auto', 'Otomatik yeniden bağlanma', 'خودکار دوبارہ کنکشن'],
  'البث (جهاز الكاميرا)': ['Streaming (camera device)', 'Diffusion (appareil caméra)', 'Yayın (kamera cihazı)', 'سٹریمنگ (کیمرہ ڈیوائس)'],
  'الدقة': ['Resolution', 'Résolution', 'Çözünürlük', 'ریزولوشن'],
  'الإطارات في الثانية (FPS)': ['Frames per second (FPS)', 'Images par seconde (FPS)', 'Saniyedeki kare (FPS)', 'فریم فی سیکنڈ (FPS)'],
  'أقصى معدل بيانات': ['Maximum bitrate', 'Débit maximal', 'En yüksek bit hızı', 'زیادہ سے زیادہ بٹ ریٹ'],
  'تلقائي': ['Auto', 'Auto', 'Otomatik', 'خودکار'],
  'الخلفية': ['Rear', 'Arrière', 'Arka', 'پچھلا'],
  'الأمامية': ['Front', 'Avant', 'Ön', 'اگلا'],
  'صوت الكاميرا': ['Camera audio', 'Audio de la caméra', 'Kamera sesi', 'کیمرے کی آواز'],
  'مكتوم': ['Muted', 'Coupé', 'Sessiz', 'خاموش'],
  'المشاهدة': ['Viewing', 'Visionnage', 'İzleme', 'دیکھنا'],
  'عرض الفيديو': ['Video fit', 'Affichage vidéo', 'Video görünümü', 'ویڈیو کا انداز'],
  'كامل بدون قص': ['Full, no crop', 'Complet, sans rognage', 'Tam, kırpmasız', 'مکمل، بغیر کٹائی'],
  'ملء الشاشة (قص)': ['Fill screen (crop)', 'Plein écran (rognage)', 'Ekranı doldur (kırp)', 'پوری اسکرین (کٹائی)'],
  'الدخول للشاشة العريضة تلقائياً': ['Enter wide screen automatically', 'Passer en grand écran automatiquement', 'Geniş ekrana otomatik geç', 'خودکار وائیڈ اسکرین'],
  'نعم': ['Yes', 'Oui', 'Evet', 'ہاں'],
  'لا': ['No', 'Non', 'Hayır', 'نہیں'],
  'المدى والشبكة': ['Range & network', 'Portée et réseau', 'Menzil ve ağ', 'رینج اور نیٹ ورک'],
  'وضع المدى البعيد (جودة أقل = ثبات أكثر)': ['Long‑range mode (lower quality = more stable)', 'Mode longue portée (qualité réduite = plus stable)', 'Uzun menzil modu (düşük kalite = daha kararlı)', 'لانگ رینج موڈ (کم معیار = زیادہ استحکام)'],
  'إيقاف': ['Off', 'Désactivé', 'Kapalı', 'بند'],
  'تشغيل': ['On', 'Activé', 'Açık', 'آن'],
  'الاتصال من خارج الشبكة المحلية (STUN)': ['Connect from outside the local network (STUN)', 'Connexion hors réseau local (STUN)', 'Yerel ağ dışından bağlan (STUN)', 'مقامی نیٹ ورک سے باہر کنکشن (STUN)'],
  'ختم التاريخ والوقت على العرض': ['Date and time stamp on the picture', 'Horodatage sur l\'image', 'Görüntüde tarih ve saat damgası', 'تصویر پر تاریخ اور وقت'],
  'إشعارات خارجية (والتطبيق مغلق)': ['External alerts (even when the app is closed)', 'Alertes externes (même app fermée)', 'Harici bildirimler (uygulama kapalıyken de)', 'بیرونی اطلاعات (ایپ بند ہونے پر بھی)'],
  'جلب Chat ID': ['Fetch Chat ID', 'Récupérer le Chat ID', 'Chat ID al', 'Chat ID حاصل کریں'],
  'إرسال اختبار': ['Send test', 'Envoyer un test', 'Test gönder', 'ٹیسٹ بھیجیں'],
  'رسالة تجريبية': ['Test message', 'Message de test', 'Test mesajı', 'ٹیسٹ پیغام'],
  'لم تُضبط أي قناة بعد': ['No channel is set up yet', 'Aucun canal configuré', 'Henüz bir kanal ayarlanmadı', 'ابھی کوئی چینل ترتیب نہیں دیا گیا'],
  'وصلت الرسالة': ['Message delivered', 'Message envoyé', 'Mesaj ulaştı', 'پیغام پہنچ گیا'],
  'فشل الإرسال: تحقق من البيانات والإنترنت': ['Sending failed: check the details and internet', 'Échec : vérifiez les données et Internet', 'Gönderilemedi: bilgileri ve interneti kontrol edin', 'بھیجنا ناکام: معلومات اور انٹرنیٹ چیک کریں'],
  'خادم ntfy (اختياري)': ['ntfy server (optional)', 'Serveur ntfy (facultatif)', 'ntfy sunucusu (isteğe bağlı)', 'ntfy سرور (اختیاری)'],
  'ملخص يومي بإشعار': ['Daily summary alert', 'Résumé quotidien', 'Günlük özet bildirimi', 'روزانہ خلاصہ اطلاع'],
  '8 م': ['8 PM', '20 h', '20:00', 'رات 8 بجے'],
  '9 م': ['9 PM', '21 h', '21:00', 'رات 9 بجے'],
  '10 م': ['10 PM', '22 h', '22:00', 'رات 10 بجے'],
  '11 م': ['11 PM', '23 h', '23:00', 'رات 11 بجے'],
  'نسخ احتياطي': ['Backup', 'Sauvegarde', 'Yedekleme', 'بیک اپ'],
  'رابط WebDAV (جهاز الكاميرا)': ['WebDAV URL (camera device)', 'URL WebDAV (appareil caméra)', 'WebDAV adresi (kamera cihazı)', 'WebDAV لنک (کیمرہ ڈیوائس)'],
  'اسم المستخدم': ['Username', 'Nom d\'utilisateur', 'Kullanıcı adı', 'صارف نام'],
  'كلمة المرور': ['Password', 'Mot de passe', 'Parola', 'پاس ورڈ'],
  'نسخ التسجيلات إلى الصور تلقائياً (جهاز المشاهدة)': ['Copy recordings to Photos automatically (viewer device)', 'Copier les enregistrements dans Photos (appareil spectateur)', 'Kayıtları otomatik olarak Fotoğraflar\'a kopyala (izleyici cihaz)', 'ریکارڈنگز خودکار طور پر فوٹوز میں کاپی کریں (ناظر ڈیوائس)'],
  'مساعدة': ['Help', 'Aide', 'Yardım', 'مدد'],
  'التنبيهات (جهاز المشاهدة)': ['Alerts (viewer device)', 'Alertes (appareil spectateur)', 'Uyarılar (izleyici cihaz)', 'اطلاعات (ناظر ڈیوائس)'],
  'تنبيه بطارية الكاميرا عند': ['Camera battery alert at', 'Alerte batterie caméra à', 'Kamera pil uyarısı', 'کیمرے کی بیٹری الرٹ'],
  'تنبيه حرارة الكاميرا عند': ['Camera temperature alert at', 'Alerte température caméra à', 'Kamera sıcaklık uyarısı', 'کیمرے کا درجہ حرارت الرٹ'],
  'صوت التنبيه': ['Alert sound', 'Son d\'alerte', 'Uyarı sesi', 'الرٹ کی آواز'],
  'اهتزاز التنبيه': ['Alert vibration', 'Vibration d\'alerte', 'Uyarı titreşimi', 'الرٹ وائبریشن'],
  'أقل فاصل بين تنبيهات الحركة والصوت': ['Minimum gap between motion and sound alerts', 'Délai minimal entre alertes mouvement/son', 'Hareket ve ses uyarıları arası en kısa süre', 'حرکت اور آواز الرٹس کے درمیان کم از کم وقفہ'],
  '10 ث': ['10 s', '10 s', '10 sn', '10 سیکنڈ'],
  '20 ث': ['20 s', '20 s', '20 sn', '20 سیکنڈ'],
  'دقيقة': ['1 min', '1 min', '1 dk', '1 منٹ'],
  'إعادة الاتصال التلقائية': ['Automatic reconnection', 'Reconnexion automatique', 'Otomatik yeniden bağlanma', 'خودکار دوبارہ کنکشن'],
  'مفعّلة': ['Enabled', 'Activée', 'Etkin', 'فعال'],
  'معطّلة': ['Disabled', 'Désactivée', 'Devre dışı', 'غیر فعال'],
  'كتم الصوت عند الاتصال': ['Mute on connect', 'Couper le son à la connexion', 'Bağlanınca sessize al', 'کنکشن پر خاموش'],
  'إبقاء الشاشة مضاءة': ['Keep screen on', 'Garder l\'écran allumé', 'Ekranı açık tut', 'اسکرین روشن رکھیں'],
  'الأمان': ['Security', 'Sécurité', 'Güvenlik', 'سیکیورٹی'],
  'محاولات PIN الخاطئة قبل القفل': ['Wrong PIN attempts before lockout', 'Essais PIN erronés avant blocage', 'Kilitlenmeden önce yanlış PIN denemesi', 'لاک سے پہلے غلط PIN کی کوششیں'],
  'مدة القفل': ['Lockout duration', 'Durée du blocage', 'Kilitlenme süresi', 'لاک کی مدت'],
  '5 دقائق': ['5 minutes', '5 minutes', '5 dakika', '5 منٹ'],
  '15 دقيقة': ['15 minutes', '15 minutes', '15 dakika', '15 منٹ'],
  'PIN جديد عند كل تشغيل للكاميرا': ['New PIN each time the camera starts', 'Nouveau PIN à chaque démarrage', 'Kamera her başladığında yeni PIN', 'کیمرہ شروع ہونے پر نیا PIN'],
  'متقدم': ['Advanced', 'Avancé', 'Gelişmiş', 'ایڈوانسڈ'],
  'نسخ معلومات التشخيص': ['Copy diagnostic info', 'Copier les infos de diagnostic', 'Tanılama bilgisini kopyala', 'تشخیصی معلومات کاپی کریں'],
  'تُنسخ بدون الـ PIN، للصقها عند طلب المساعدة': ['Copied without the PIN, to paste when asking for help', 'Copié sans le PIN, à coller pour demander de l\'aide', 'PIN olmadan kopyalanır, yardım isterken yapıştırın', 'PIN کے بغیر کاپی ہوتی ہے، مدد مانگتے وقت چسپاں کریں'],
  'إعادة ضبط كل الإعدادات': ['Reset all settings', 'Réinitialiser tous les réglages', 'Tüm ayarları sıfırla', 'تمام سیٹنگز ری سیٹ کریں'],
  'تُحذف الإعدادات والكاميرات المحفوظة': ['Settings and saved cameras are deleted', 'Réglages et caméras enregistrées supprimés', 'Ayarlar ve kayıtlı kameralar silinir', 'سیٹنگز اور محفوظ کیمرے حذف ہوں گے'],
  'إعادة ضبط كل شيء؟': ['Reset everything?', 'Tout réinitialiser ?', 'Her şey sıfırlansın mı?', 'سب کچھ ری سیٹ کریں؟'],
  'إلغاء': ['Cancel', 'Annuler', 'İptal', 'منسوخ'],
  'إعادة ضبط': ['Reset', 'Réinitialiser', 'Sıfırla', 'ری سیٹ'],
  'مشاركة الشاشة والتحكم': ['Screen sharing & control', 'Partage d\'écran et contrôle', 'Ekran paylaşımı ve kontrol', 'اسکرین شیئرنگ اور کنٹرول'],
  'الإطارات في الثانية (الحد الأعلى)': ['Frames per second (maximum)', 'Images par seconde (max)', 'Saniyedeki kare (en çok)', 'فریم فی سیکنڈ (زیادہ سے زیادہ)'],
  'جودة الصورة': ['Image quality', 'Qualité d\'image', 'Görüntü kalitesi', 'تصویر کا معیار'],
  'سريعة جداً': ['Very fast', 'Très rapide', 'Çok hızlı', 'بہت تیز'],
  'سريعة': ['Fast', 'Rapide', 'Hızlı', 'تیز'],
  'متوازنة': ['Balanced', 'Équilibrée', 'Dengeli', 'متوازن'],
  'بانتظار المشاهد': ['Waiting for a viewer', 'En attente d\'un spectateur', 'İzleyici bekleniyor', 'ناظر کا انتظار'],
  'بطارية الكاميرا منخفضة': ['Camera battery low', 'Batterie de la caméra faible', 'Kamera pili düşük', 'کیمرے کی بیٹری کم ہے'],
  'فُصل الشاحن': ['Charger disconnected', 'Chargeur débranché', 'Şarj cihazı çıkarıldı', 'چارجر ہٹا دیا گیا'],
  'صوت عالٍ عند الكاميرا': ['Loud sound at the camera', 'Son fort près de la caméra', 'Kamerada yüksek ses', 'کیمرے کے پاس تیز آواز'],
  'حركة مكتشفة': ['Motion detected', 'Mouvement détecté', 'Hareket algılandı', 'حرکت کا پتہ چلا'],
  'ملخص اليوم': ['Daily summary', 'Résumé du jour', 'Günün özeti', 'آج کا خلاصہ'],
  'اليوم': ['Today', 'Aujourd\'hui', 'Bugün', 'آج'],
  'ربط سريع عبر QR': ['Quick pairing with QR', 'Association rapide par QR', 'QR ile hızlı eşleştirme', 'QR سے فوری جوڑیں'],
  'تحكم كامل': ['Full control', 'Contrôle total', 'Tam kontrol', 'مکمل کنٹرول'],
  'مشاهدة فقط': ['View only', 'Lecture seule', 'Yalnızca izleme', 'صرف دیکھنا'],
  'الرمز يحتوي على الـ PIN — لا تعرضه لأحد لا تثق به.': ['The code contains the PIN — don\'t show it to anyone you don\'t trust.', 'Le code contient le PIN — ne le montrez qu\'à des personnes de confiance.', 'Kod PIN içerir — güvenmediğiniz kimseye göstermeyin.', 'کوڈ میں PIN ہے — کسی غیر معتبر کو نہ دکھائیں۔'],
  'إغلاق': ['Close', 'Fermer', 'Kapat', 'بند کریں'],
  'الشاشة جاهزة للمشاهدة': ['Screen ready to view', 'Écran prêt à être visionné', 'Ekran izlemeye hazır', 'اسکرین دیکھنے کے لیے تیار'],
  'التحكم عن بعد مفعّل': ['Remote control enabled', 'Contrôle à distance activé', 'Uzaktan kontrol açık', 'ریموٹ کنٹرول فعال'],
  'إيقاف مشاركة الشاشة': ['Stop screen sharing', 'Arrêter le partage d\'écran', 'Ekran paylaşımını durdur', 'اسکرین شیئرنگ بند کریں'],
  'بدء مشاركة الشاشة': ['Start screen sharing', 'Démarrer le partage d\'écran', 'Ekran paylaşımını başlat', 'اسکرین شیئرنگ شروع کریں'],
  'تفعيل التحكم (إمكانية الوصول)': ['Enable control (Accessibility)', 'Activer le contrôle (Accessibilité)', 'Kontrolü etkinleştir (Erişilebilirlik)', 'کنٹرول فعال کریں (ایکسیسبیلٹی)'],
  'العنوان': ['Address', 'Adresse', 'Adres', 'ایڈریس'],
  'رمز الدخول (PIN)': ['Access code (PIN)', 'Code d\'accès (PIN)', 'Giriş kodu (PIN)', 'رسائی کوڈ (PIN)'],
  'رمز المشاهدة فقط': ['View‑only code', 'Code lecture seule', 'Yalnızca izleme kodu', 'صرف دیکھنے کا کوڈ'],
  'متصل — يوجد مشاهد': ['Connected — a viewer is watching', 'Connecté — un spectateur regarde', 'Bağlı — bir izleyici var', 'کنکٹڈ — ناظر موجود ہے'],
  'عرض رمز QR للربط': ['Show pairing QR code', 'Afficher le code QR', 'Eşleştirme QR kodunu göster', 'جوڑنے کا QR کوڈ دکھائیں'],
  'الاتصال مشفّر (TLS)': ['Connection encrypted (TLS)', 'Connexion chiffrée (TLS)', 'Bağlantı şifreli (TLS)', 'کنکشن خفیہ (TLS)'],
  'الاتصال غير مشفّر — أضف شهادة TLS في البناء': ['Connection not encrypted — add a TLS certificate in the build', 'Connexion non chiffrée — ajoutez un certificat TLS', 'Bağlantı şifresiz — derlemeye TLS sertifikası ekleyin', 'کنکشن خفیہ نہیں — بلڈ میں TLS سرٹیفکیٹ شامل کریں'],
  'كشف الحركة': ['Motion detection', 'Détection de mouvement', 'Hareket algılama', 'حرکت کی شناخت'],
  'الإعدادات الكاملة من جهاز المشاهدة (زر الأمان)': ['Full settings from the viewer device (Security button)', 'Réglages complets depuis l\'appareil spectateur (bouton Sécurité)', 'Tüm ayarlar izleyici cihazdan (Güvenlik düğmesi)', 'مکمل سیٹنگز ناظر ڈیوائس سے (سیکیورٹی بٹن)'],
  'توفير الطاقة': ['Power saving', 'Économie d\'énergie', 'Güç tasarrufu', 'بجلی کی بچت'],
  'شاشة سوداء إذا لم يشاهد أحد لمدة دقيقة': ['Black screen if nobody watches for a minute', 'Écran noir si personne ne regarde pendant une minute', 'Bir dakika kimse izlemezse siyah ekran', 'ایک منٹ تک کوئی نہ دیکھے تو سیاہ اسکرین'],
  'جاهزية دائمة': ['Always ready', 'Toujours prêt', 'Her zaman hazır', 'ہمیشہ تیار'],
  'اتصل في أي وقت حتى لو التطبيق مغلق': ['Connect any time, even if the app is closed', 'Connectez-vous à tout moment, même app fermée', 'Uygulama kapalı olsa bile istediğiniz zaman bağlanın', 'ایپ بند ہو تب بھی کسی بھی وقت جڑیں'],
  'بدء الكاميرا عند الشحن': ['Start camera when charging', 'Démarrer la caméra au branchement', 'Şarja takılınca kamerayı başlat', 'چارجنگ پر کیمرہ شروع کریں'],
  'وصّل الشاحن فتبدأ الكاميرا تلقائياً': ['Plug in the charger and the camera starts automatically', 'Branchez le chargeur : la caméra démarre seule', 'Şarjı takın, kamera otomatik başlar', 'چارجر لگائیں، کیمرہ خود شروع ہو جائے گا'],
  'إيقاف التسجيل': ['Stop recording', 'Arrêter l\'enregistrement', 'Kaydı durdur', 'ریکارڈنگ بند کریں'],
  'التسجيل متاح على Android فقط': ['Recording is available on Android only', 'Enregistrement disponible sur Android uniquement', 'Kayıt yalnızca Android\'de', 'ریکارڈنگ صرف اینڈرائیڈ پر دستیاب'],
  'حركة': ['Motion', 'Mouvement', 'Hareket', 'حرکت'],
  'وضع توفير الطاقة — المس الشاشة': ['Power‑saving mode — touch the screen', 'Mode économie d\'énergie — touchez l\'écran', 'Güç tasarrufu modu — ekrana dokunun', 'بجلی بچت موڈ — اسکرین کو چھوئیں'],
  'منزل': ['Home', 'Maison', 'Ev', 'گھر'],
  'غرفة طفل': ['Baby room', 'Chambre de bébé', 'Bebek odası', 'بچے کا کمرہ'],
  'متجر': ['Shop', 'Boutique', 'Mağaza', 'دکان'],
  'جاري البحث عن الكاميرات...': ['Searching for cameras...', 'Recherche de caméras...', 'Kameralar aranıyor...', 'کیمرے تلاش کیے جا رہے ہیں...'],
  'ما لقيت كاميرا على الشبكة': ['No camera found on the network', 'Aucune caméra trouvée sur le réseau', 'Ağda kamera bulunamadı', 'نیٹ ورک پر کوئی کیمرہ نہیں ملا'],
  'تم إيقاف المحاولة': ['Retry stopped', 'Tentative arrêtée', 'Deneme durduruldu', 'کوشش روک دی گئی'],
  'انقطع الاتصال بالكاميرا — جاري إعادة الاتصال': ['Camera disconnected — reconnecting', 'Caméra déconnectée — reconnexion', 'Kamera bağlantısı koptu — yeniden bağlanıyor', 'کیمرے سے رابطہ ٹوٹ گیا — دوبارہ جڑ رہا ہے'],
  'اكتب IP الكاميرا أو اضغط بحث': ['Enter the camera IP or tap Search', 'Saisissez l\'IP de la caméra ou touchez Rechercher', 'Kamera IP\'sini yazın veya Ara\'ya dokunun', 'کیمرے کا IP لکھیں یا تلاش دبائیں'],
  'جاري الاتصال...': ['Connecting...', 'Connexion...', 'Bağlanıyor...', 'جڑ رہا ہے...'],
  'الكاميرا مغلقة — جاري إيقاظها...': ['Camera is off — waking it...', 'Caméra éteinte — réveil...', 'Kamera kapalı — uyandırılıyor...', 'کیمرہ بند ہے — جگایا جا رہا ہے...'],
  'PIN غير صحيح': ['Wrong PIN', 'PIN incorrect', 'PIN yanlış', 'PIN غلط ہے'],
  'محاولات خاطئة كثيرة — انتظر 5 دقائق': ['Too many wrong attempts — wait 5 minutes', 'Trop d\'essais erronés — attendez 5 minutes', 'Çok fazla hatalı deneme — 5 dakika bekleyin', 'بہت زیادہ غلط کوششیں — 5 منٹ انتظار کریں'],
  'رمز غير صالح': ['Invalid code', 'Code invalide', 'Geçersiz kod', 'غلط کوڈ'],
  'لا يوجد بث': ['No stream', 'Pas de flux', 'Yayın yok', 'کوئی سٹریم نہیں'],
  'تم حفظ اللقطة في الصور': ['Snapshot saved to Photos', 'Capture enregistrée dans Photos', 'Görüntü Fotoğraflar\'a kaydedildi', 'تصویر فوٹوز میں محفوظ ہو گئی'],
  'تعذّر التقاط الصورة': ['Could not capture the image', 'Impossible de capturer l\'image', 'Görüntü alınamadı', 'تصویر نہیں لی جا سکی'],
  'رؤية ليلية (تحسين العرض)': ['Night view (display enhancement)', 'Vision nocturne (amélioration d\'affichage)', 'Gece görüşü (görüntü iyileştirme)', 'رات کا منظر (ڈسپلے بہتری)'],
  'ليلي': ['Night', 'Nuit', 'Gece', 'رات'],
  'ليلي قوي': ['Strong night', 'Nuit renforcé', 'Güçlü gece', 'تیز رات'],
  'ختم التاريخ والوقت': ['Date & time stamp', 'Horodatage', 'Tarih ve saat damgası', 'تاریخ اور وقت'],
  'وضع المدى البعيد': ['Long‑range mode', 'Mode longue portée', 'Uzun menzil modu', 'لانگ رینج موڈ'],
  'يخفّض الجودة ليبقى الاتصال ثابتاً مع الإشارة الضعيفة': ['Lowers quality to keep the link stable on a weak signal', 'Réduit la qualité pour garder le lien stable', 'Zayıf sinyalde bağlantıyı korumak için kaliteyi düşürür', 'کمزور سگنل پر کنکشن مستحکم رکھنے کے لیے معیار کم کرتا ہے'],
  'إعادة ضبط الزوم': ['Reset zoom', 'Réinitialiser le zoom', 'Yakınlaştırmayı sıfırla', 'زوم ری سیٹ کریں'],
  'حركة مكتشفة في الكاميرا': ['Motion detected at the camera', 'Mouvement détecté à la caméra', 'Kamerada hareket algılandı', 'کیمرے پر حرکت کا پتہ چلا'],
  'تجاهل المناطق': ['Ignore zones', 'Ignorer les zones', 'Bölgeleri yoksay', 'زونز نظر انداز کریں'],
  'مراقبة المناطق فقط': ['Watch zones only', 'Surveiller les zones seulement', 'Yalnızca bölgeleri izle', 'صرف زونز کی نگرانی'],
  'مسح': ['Clear', 'Effacer', 'Temizle', 'صاف کریں'],
  'الأمان والمراقبة الذكية': ['Security & smart monitoring', 'Sécurité et surveillance intelligente', 'Güvenlik ve akıllı izleme', 'سیکیورٹی اور سمارٹ نگرانی'],
  'تنبيه مع لقطة عند وجود حركة': ['Alert with a snapshot when there is motion', 'Alerte avec capture en cas de mouvement', 'Hareket olunca görüntülü uyarı', 'حرکت پر تصویر کے ساتھ الرٹ'],
  'تسجيل تلقائي عند الحركة': ['Auto‑record on motion', 'Enregistrement auto sur mouvement', 'Harekette otomatik kayıt', 'حرکت پر خودکار ریکارڈنگ'],
  'الحساسية': ['Sensitivity', 'Sensibilité', 'Hassasiyet', 'حساسیت'],
  'تصفية الإنذارات الكاذبة': ['False‑alarm filter', 'Filtre de fausses alertes', 'Yanlış alarm filtresi', 'غلط الارم فلٹر'],
  'تسجيل ما قبل الحركة': ['Pre‑motion recording', 'Enregistrement pré‑mouvement', 'Hareket öncesi kayıt', 'حرکت سے پہلے کی ریکارڈنگ'],
  'اعتماد الأشخاص فقط': ['Count people only', 'Compter uniquement les personnes', 'Yalnızca kişileri say', 'صرف افراد شمار کریں'],
  'كشف الصوت': ['Sound detection', 'Détection sonore', 'Ses algılama', 'آواز کی شناخت'],
  'جدول زمني': ['Schedule', 'Planning', 'Zamanlama', 'شیڈول'],
  'الحركة والصوت يعملان في هذه الساعات فقط': ['Motion and sound work only during these hours', 'Mouvement et son actifs seulement à ces heures', 'Hareket ve ses yalnızca bu saatlerde çalışır', 'حرکت اور آواز صرف انہی اوقات میں کام کرتے ہیں'],
  'من': ['From', 'De', 'Başlangıç', 'سے'],
  'إلى': ['To', 'À', 'Bitiş', 'تک'],
  'مكتبة التسجيلات والأحداث': ['Recordings & events library', 'Bibliothèque d\'enregistrements et d\'événements', 'Kayıt ve olay kitaplığı', 'ریکارڈنگز اور ایونٹس لائبریری'],
  'تصفح وتنزيل وحذف من جهاز الكاميرا': ['Browse, download and delete from the camera device', 'Parcourir, télécharger et supprimer depuis la caméra', 'Kamera cihazından gözat, indir, sil', 'کیمرہ ڈیوائس سے دیکھیں، ڈاؤن لوڈ اور حذف کریں'],
  'تشغيل صفارة على الكاميرا': ['Sound a siren on the camera', 'Déclencher une sirène sur la caméra', 'Kamerada siren çal', 'کیمرے پر سائرن بجائیں'],
  'نغمة تنبيه واهتزاز لمدة 15 ثانية': ['Alert tone and vibration for 15 seconds', 'Tonalité et vibration pendant 15 s', '15 saniye uyarı sesi ve titreşim', '15 سیکنڈ الرٹ ٹون اور وائبریشن'],
  'تحديد مناطق الكشف': ['Set detection zones', 'Définir les zones de détection', 'Algılama bölgelerini belirle', 'شناخت کے زونز مقرر کریں'],
  'تسجيل دوّار (حذف الأقدم تلقائياً)': ['Loop recording (delete oldest automatically)', 'Enregistrement en boucle (supprime les plus anciens)', 'Döngüsel kayıt (en eskiyi otomatik sil)', 'لوپ ریکارڈنگ (پرانی خودکار حذف)'],
  'تصوير زمني (لقطة كل)': ['Time‑lapse (a frame every)', 'Time‑lapse (une image toutes les)', 'Zaman atlamalı (her ... bir kare)', 'ٹائم لیپس (ہر ... پر فریم)'],
  'لا توجد أحداث بعد': ['No events yet', 'Aucun événement', 'Henüz olay yok', 'ابھی کوئی ایونٹ نہیں'],
  'لحظة الحدث': ['Moment of the event', 'Moment de l\'événement', 'Olay anı', 'ایونٹ کا لمحہ'],
  'بعد 3 ثوانٍ': ['After 3 seconds', '3 secondes après', '3 saniye sonra', '3 سیکنڈ بعد'],
  'تم الحفظ في الصور': ['Saved to Photos', 'Enregistré dans Photos', 'Fotoğraflar\'a kaydedildi', 'فوٹوز میں محفوظ ہو گیا'],
  'تعذّر الحفظ': ['Could not save', 'Échec de l\'enregistrement', 'Kaydedilemedi', 'محفوظ نہیں ہو سکا'],
  'حفظ في الصور': ['Save to Photos', 'Enregistrer dans Photos', 'Fotoğraflar\'a kaydet', 'فوٹوز میں محفوظ کریں'],
  'متصل — التحكم مفعّل': ['Connected — control enabled', 'Connecté — contrôle activé', 'Bağlı — kontrol açık', 'کنکٹڈ — کنٹرول فعال'],
  'رجوع': ['Back', 'Retour', 'Geri', 'واپس'],
  'الرئيسية': ['Home', 'Accueil', 'Ana ekran', 'ہوم'],
  'التطبيقات': ['Apps', 'Applications', 'Uygulamalar', 'ایپس'],
  'الإشعارات': ['Notifications', 'Notifications', 'Bildirimler', 'اطلاعات'],
  'تصغير': ['Shrink', 'Réduire', 'Küçült', 'چھوٹا کریں'],
  'عريض': ['Wide', 'Large', 'Geniş', 'وسیع'],
  'اتصل بالكاميرا أولاً': ['Connect to the camera first', 'Connectez-vous d\'abord à la caméra', 'Önce kameraya bağlanın', 'پہلے کیمرے سے جڑیں'],
  'الصوت': ['Sound', 'Son', 'Ses', 'آواز'],
  'لقطة': ['Snapshot', 'Capture', 'Görüntü al', 'تصویر'],
  'التسجيلات': ['Recordings', 'Enregistrements', 'Kayıtlar', 'ریکارڈنگز'],
  'ميكروفون': ['Mic', 'Micro', 'Mikrofon', 'مائیک'],
  'قلب': ['Flip', 'Retourner', 'Çevir', 'پلٹیں'],
  'فلاش': ['Torch', 'Lampe', 'Fener', 'ٹارچ'],
  'الأحداث': ['Events', 'Événements', 'Olaylar', 'ایونٹس'],
  'بحث': ['Search', 'Rechercher', 'Ara', 'تلاش'],
  'اتصال': ['Connect', 'Connexion', 'Bağlan', 'جڑیں'],
  'تعديل الاسم واللون': ['Edit name & colour', 'Modifier nom et couleur', 'Ad ve rengi düzenle', 'نام اور رنگ ایڈٹ کریں'],
  'تقديم': ['Move earlier', 'Avancer', 'Öne al', 'آگے کریں'],
  'تأخير': ['Move later', 'Reculer', 'Geriye al', 'پیچھے کریں'],
  'حذف': ['Delete', 'Supprimer', 'Sil', 'حذف کریں'],
  'أضف حتى 4 كاميرات وشاهدها معاً': ['Add up to 4 cameras and watch them together', 'Ajoutez jusqu\'à 4 caméras', 'En fazla 4 kamera ekleyip birlikte izleyin', '4 کیمرے تک شامل کر کے ایک ساتھ دیکھیں'],
  'إضافة كاميرا': ['Add a camera', 'Ajouter une caméra', 'Kamera ekle', 'کیمرہ شامل کریں'],
  'الاسم (مثلاً: المدخل)': ['Name (e.g. Entrance)', 'Nom (ex. Entrée)', 'Ad (ör. Giriş)', 'نام (مثلاً: داخلی دروازہ)'],
  'إضافة': ['Add', 'Ajouter', 'Ekle', 'شامل کریں'],
  'حفظ': ['Save', 'Enregistrer', 'Kaydet', 'محفوظ کریں'],
  'الكاميرا غير متاحة': ['Camera unavailable', 'Caméra indisponible', 'Kamera kullanılamıyor', 'کیمرہ دستیاب نہیں'],
  'الكاميرا لا تستجيب': ['Camera not responding', 'La caméra ne répond pas', 'Kamera yanıt vermiyor', 'کیمرہ جواب نہیں دے رہا'],
  'تعذّر الاتصال': ['Could not connect', 'Connexion impossible', 'Bağlanılamadı', 'کنکشن نہیں ہو سکا'],
  'انتهت المهلة': ['Timed out', 'Délai dépassé', 'Zaman aşımı', 'وقت ختم ہو گیا'],
  'تعذّر جلب القائمة': ['Could not load the list', 'Impossible de charger la liste', 'Liste alınamadı', 'فہرست حاصل نہیں ہو سکی'],
  'تعذّر الاتصال بالكاميرا': ['Could not reach the camera', 'Impossible de joindre la caméra', 'Kameraya ulaşılamadı', 'کیمرے تک رسائی نہیں ہو سکی'],
  'تم تنزيل التسجيل وحفظه في الصور': ['Recording downloaded and saved to Photos', 'Enregistrement téléchargé et ajouté à Photos', 'Kayıt indirildi ve Fotoğraflar\'a kaydedildi', 'ریکارڈنگ ڈاؤن لوڈ ہو کر فوٹوز میں محفوظ ہو گئی'],
  'تعذّر تنزيل التسجيل': ['Could not download the recording', 'Impossible de télécharger', 'Kayıt indirilemedi', 'ریکارڈنگ ڈاؤن لوڈ نہیں ہو سکی'],
  'حذف من جهاز الكاميرا؟': ['Delete from the camera device?', 'Supprimer de la caméra ?', 'Kamera cihazından silinsin mi?', 'کیمرہ ڈیوائس سے حذف کریں؟'],
  'تعذّر الحذف': ['Could not delete', 'Suppression impossible', 'Silinemedi', 'حذف نہیں ہو سکا'],
  'ملخص الأحداث': ['Events summary', 'Résumé des événements', 'Olay özeti', 'ایونٹس کا خلاصہ'],
  'أمس': ['Yesterday', 'Hier', 'Dün', 'کل'],
  'تنزيل إلى الصور': ['Download to Photos', 'Télécharger dans Photos', 'Fotoğraflar\'a indir', 'فوٹوز میں ڈاؤن لوڈ کریں'],
  'لقطة حدث': ['Event snapshot', 'Capture d\'événement', 'Olay görüntüsü', 'ایونٹ کی تصویر'],
  'تسجيلات وأحداث الكاميرا': ['Camera recordings & events', 'Enregistrements et événements', 'Kamera kayıtları ve olayları', 'کیمرے کی ریکارڈنگز اور ایونٹس'],
  'لا توجد تسجيلات أو أحداث': ['No recordings or events', 'Aucun enregistrement ni événement', 'Kayıt veya olay yok', 'کوئی ریکارڈنگ یا ایونٹ نہیں'],
  'لا توجد لقطات': ['No frames', 'Aucune image', 'Kare yok', 'کوئی فریم نہیں'],
  'افتح LAN Cam': ['Open LAN Cam', 'Ouvrir LAN Cam', 'LAN Cam\'i aç', 'LAN Cam کھولیں'],
  'التطبيق مقفل': ['The app is locked', 'L\'application est verrouillée', 'Uygulama kilitli', 'ایپ مقفل ہے'],
  'فتح بالبصمة أو الوجه': ['Unlock with fingerprint or face', 'Déverrouiller par empreinte ou visage', 'Parmak izi veya yüzle aç', 'فنگر پرنٹ یا چہرے سے کھولیں'],
  'الرمز غير صحيح': ['Wrong code', 'Code incorrect', 'Kod yanlış', 'کوڈ غلط ہے'],
  'ساعدني': ['Help me', 'Aidez-moi', 'Bana yardım et', 'میری مدد کریں'],
  'فحص سريع مع أزرار إصلاح': ['Quick check with fix buttons', 'Vérification rapide avec boutons de réparation', 'Düzeltme düğmeli hızlı kontrol', 'فوری جانچ مع ٹھیک کرنے کے بٹن'],
  'أدلة مصورة': ['Illustrated guides', 'Guides illustrés', 'Resimli rehberler', 'تصویری رہنما'],
  'تثبيت الكاميرا في مكانها': ['Mounting the camera', 'Installer la caméra', 'Kamerayı yerleştirme', 'کیمرہ لگانا'],
  'ضبط مناطق الكشف': ['Setting detection zones', 'Régler les zones de détection', 'Algılama bölgelerini ayarlama', 'شناخت کے زونز مقرر کرنا'],
  'فتح الأذونات': ['Granting permissions', 'Accorder les autorisations', 'İzinleri verme', 'اجازتیں دینا'],
  'المشاهدة من خارج البيت': ['Watching from outside home', 'Regarder hors de la maison', 'Evin dışından izleme', 'گھر سے باہر دیکھنا'],
  'المشاهدة من المتصفح': ['Watching from a browser', 'Regarder depuis un navigateur', 'Tarayıcıdan izleme', 'براؤزر سے دیکھنا'],
  'اختر المكان': ['Choose the spot', 'Choisissez l\'emplacement', 'Yeri seçin', 'جگہ چنیں'],
  'اختر مكاناً مرتفعاً يرى المنطقة كلها، وبعيداً عن الضوء المباشر.': ['Pick a high spot that sees the whole area, away from direct light.', 'Choisissez un endroit élevé qui voit toute la zone, loin de la lumière directe.', 'Tüm alanı gören yüksek bir yer seçin, doğrudan ışıktan uzak.', 'ایسی اونچی جگہ چنیں جو پورا علاقہ دیکھے، براہِ راست روشنی سے دور۔'],
  'ثبّت الهاتف': ['Fix the phone in place', 'Fixez le téléphone', 'Telefonu sabitleyin', 'فون کو جما دیں'],
  'ثبّت الهاتف أفقياً بحامل أو شريط لاصق، وتأكد أن العدسة غير محجوبة.': ['Mount it horizontally with a stand or tape, and make sure the lens is not blocked.', 'Fixez-le à l\'horizontale avec un support ou du ruban, objectif dégagé.', 'Yatay olarak bir stand veya bantla sabitleyin, lens kapalı olmasın.', 'اسے افقی طور پر اسٹینڈ یا ٹیپ سے لگائیں، لینس بند نہ ہو۔'],
  'وصّل الشاحن': ['Connect the charger', 'Branchez le chargeur', 'Şarjı takın', 'چارجر لگائیں'],
  'ابقِ الهاتف على الشاحن، وفعّل "جاهزية دائمة" و"بدء الكاميرا عند الشحن".': ['Keep the phone charging and turn on "Always ready" and "Start camera when charging".', 'Laissez le téléphone en charge et activez « Toujours prêt » et « Démarrer la caméra au branchement ».', 'Telefonu şarjda tutun ve "Her zaman hazır" ile "Şarja takılınca kamerayı başlat"ı açın.', 'فون چارج پر رکھیں اور "ہمیشہ تیار" اور "چارجنگ پر کیمرہ شروع کریں" آن کریں۔'],
  'تأكد من الإشارة': ['Check the signal', 'Vérifiez le signal', 'Sinyali kontrol edin', 'سگنل چیک کریں'],
  'قوة الواي فاي في المكان مهمة. جرّب البث وراقب مؤشر "اتصال قوي".': ['Wi‑Fi strength at that spot matters. Try the stream and watch the "Strong link" indicator.', 'La force du Wi‑Fi à cet endroit compte. Essayez le flux et surveillez l\'indicateur « Lien fort ».', 'O noktadaki Wi‑Fi gücü önemlidir. Yayını deneyin ve "Güçlü bağlantı" göstergesine bakın.', 'اس جگہ وائی فائی کی طاقت اہم ہے۔ سٹریم آزمائیں اور "مضبوط کنکشن" کا نشان دیکھیں۔'],
  'افتح الأمان': ['Open Security', 'Ouvrez Sécurité', 'Güvenliği açın', 'سیکیورٹی کھولیں'],
  'من شاشة المشاهدة اضغط "الأمان" ثم "تحديد مناطق الكشف".': ['On the viewing screen tap "Security", then "Set detection zones".', 'Sur l\'écran de visionnage, touchez « Sécurité » puis « Définir les zones de détection ».', 'İzleme ekranında "Güvenlik", sonra "Algılama bölgelerini belirle"ye dokunun.', 'دیکھنے کی اسکرین پر "سیکیورٹی" پھر "شناخت کے زونز مقرر کریں" دبائیں۔'],
  'لوّن الخانات': ['Paint the cells', 'Coloriez les cases', 'Hücreleri boyayın', 'خانوں پر رنگ لگائیں'],
  'مرّر إصبعك على الخانات التي تريد تجاهلها، مثل شجرة تتحرك أو شارع.': ['Drag your finger over the cells you want to ignore, like a moving tree or a street.', 'Faites glisser le doigt sur les cases à ignorer, comme un arbre qui bouge ou une rue.', 'Yok saymak istediğiniz hücrelerin üzerinde parmağınızı gezdirin (hareket eden ağaç, sokak gibi).', 'جن خانوں کو نظر انداز کرنا ہے ان پر انگلی پھیریں، جیسے ہلتا درخت یا سڑک۔'],
  'اختر الوضع': ['Choose the mode', 'Choisissez le mode', 'Modu seçin', 'موڈ چنیں'],
  'اختر "تجاهل المناطق" أو "مراقبة المناطق فقط" حسب حاجتك.': ['Choose "Ignore zones" or "Watch zones only" as you need.', 'Choisissez « Ignorer les zones » ou « Surveiller les zones seulement » selon le besoin.', 'İhtiyacınıza göre "Bölgeleri yoksay" veya "Yalnızca bölgeleri izle"yi seçin.', 'ضرورت کے مطابق "زونز نظر انداز کریں" یا "صرف زونز کی نگرانی" چنیں۔'],
  'احفظ': ['Save', 'Enregistrez', 'Kaydedin', 'محفوظ کریں'],
  'اضغط "تم". جرّب بتحريك يدك أمام الكاميرا للتأكد.': ['Tap "Done". Wave your hand in front of the camera to test.', 'Touchez « Terminé ». Agitez la main devant la caméra pour tester.', '"Tamam"a dokunun. Test için elinizi kameranın önünde sallayın.', '"ہو گیا" دبائیں۔ جانچ کے لیے کیمرے کے سامنے ہاتھ ہلائیں۔'],
  'الكاميرا والميكروفون': ['Camera and microphone', 'Caméra et micro', 'Kamera ve mikrofon', 'کیمرہ اور مائیکروفون'],
  'اضغط "السماح" عند الطلب، وهما ضروريان للبث والصوت.': ['Tap "Allow" when asked; both are required for video and sound.', 'Touchez « Autoriser » quand on vous le demande ; les deux sont nécessaires.', 'İstendiğinde "İzin ver"e dokunun; yayın ve ses için gereklidir.', 'پوچھنے پر "اجازت دیں" دبائیں؛ دونوں ویڈیو اور آواز کے لیے ضروری ہیں۔'],
  'استثناء البطارية': ['Battery exemption', 'Exemption batterie', 'Pil muafiyeti', 'بیٹری استثنا'],
  'يمنع النظام من إغلاق التطبيق وهو يعمل في الخلفية.': ['Stops the system from closing the app while it runs in the background.', 'Empêche le système de fermer l\'app en arrière-plan.', 'Sistemin arka planda çalışan uygulamayı kapatmasını engeller.', 'سسٹم کو بیک گراؤنڈ میں چلتی ایپ بند کرنے سے روکتا ہے۔'],
  'يلزم لإيقاظ الكاميرا وهي مغلقة.': ['Needed to wake the camera while it is closed.', 'Nécessaire pour réveiller la caméra fermée.', 'Kapalıyken kamerayı uyandırmak için gerekir.', 'بند کیمرے کو جگانے کے لیے ضروری ہے۔'],
  'إمكانية الوصول (اختياري)': ['Accessibility (optional)', 'Accessibilité (facultatif)', 'Erişilebilirlik (isteğe bağlı)', 'ایکسیسبیلٹی (اختیاری)'],
  'للتحكم بشاشة الهاتف عن بعد. افتح فحص المشاكل لمتابعة الخطوات.': ['For controlling the phone screen remotely. Open the problem check to continue.', 'Pour contrôler l\'écran à distance. Ouvrez le diagnostic pour continuer.', 'Telefon ekranını uzaktan kontrol etmek için. Devam etmek için sorun kontrolünü açın.', 'فون اسکرین کو دور سے کنٹرول کرنے کے لیے۔ آگے بڑھنے کو مسئلہ جانچ کھولیں۔'],
  'ثبّت Tailscale': ['Install Tailscale', 'Installez Tailscale', 'Tailscale\'i kurun', 'Tailscale انسٹال کریں'],
  'ثبّت تطبيق Tailscale المجاني على هاتف الكاميرا وهاتف المشاهد.': ['Install the free Tailscale app on both the camera phone and the viewer phone.', 'Installez l\'app gratuite Tailscale sur le téléphone caméra et le téléphone spectateur.', 'Ücretsiz Tailscale uygulamasını hem kamera hem izleyici telefonuna kurun.', 'مفت Tailscale ایپ کیمرہ فون اور ناظر فون دونوں پر انسٹال کریں۔'],
  'سجّل بنفس الحساب': ['Sign in with the same account', 'Connectez-vous avec le même compte', 'Aynı hesapla giriş yapın', 'ایک ہی اکاؤنٹ سے لاگ اِن کریں'],
  'سجّل الدخول في التطبيقين بنفس الحساب، وفعّل الاتصال (VPN).': ['Sign in to both apps with the same account and turn the connection (VPN) on.', 'Connectez-vous aux deux apps avec le même compte et activez la connexion (VPN).', 'İki uygulamada da aynı hesapla giriş yapın ve bağlantıyı (VPN) açın.', 'دونوں ایپس میں ایک ہی اکاؤنٹ سے لاگ اِن کریں اور کنکشن (VPN) آن کریں۔'],
  'اعرف عنوان الكاميرا': ['Find the camera address', 'Trouvez l\'adresse de la caméra', 'Kamera adresini bulun', 'کیمرے کا ایڈریس معلوم کریں'],
  'على هاتف الكاميرا يظهر عنوان يبدأ بـ 100. بجانب كلمة VPN. استخدمه بدل عنوان الواي فاي.': ['On the camera phone an address starting with 100. appears next to "VPN". Use it instead of the Wi‑Fi address.', 'Sur le téléphone caméra, une adresse commençant par 100. apparaît près de « VPN ». Utilisez-la à la place de l\'adresse Wi‑Fi.', 'Kamera telefonunda "VPN" yanında 100. ile başlayan bir adres görünür. Wi‑Fi adresi yerine onu kullanın.', 'کیمرہ فون پر "VPN" کے ساتھ 100. سے شروع ہونے والا ایڈریس نظر آتا ہے۔ وائی فائی ایڈریس کی جگہ یہ استعمال کریں۔'],
  'جرّب الاتصال': ['Try the connection', 'Essayez la connexion', 'Bağlantıyı deneyin', 'کنکشن آزمائیں'],
  'اكتب ذلك العنوان في المشاهد أو في "اختبار الاتصال". لا تفتح منافذ الراوتر.': ['Enter that address in the viewer or in "Test connection". Do not open router ports.', 'Saisissez cette adresse dans le spectateur ou dans « Tester la connexion ». N\'ouvrez pas de ports sur le routeur.', 'Bu adresi izleyiciye veya "Bağlantıyı test et"e yazın. Router portlarını açmayın.', 'یہ ایڈریس ناظر میں یا "کنکشن ٹیسٹ" میں لکھیں۔ راؤٹر کے پورٹ نہ کھولیں۔'],
  'لم يُكتشف Tailscale على هذا الهاتف بعد': ['Tailscale was not detected on this phone yet', 'Tailscale n\'est pas encore détecté sur ce téléphone', 'Bu telefonda henüz Tailscale algılanmadı', 'اس فون پر ابھی Tailscale نہیں ملا'],
  'افتح الرابط': ['Open the link', 'Ouvrez le lien', 'Bağlantıyı açın', 'لنک کھولیں'],
  'على أي جهاز على نفس الشبكة افتح الرابط المعروض على هاتف الكاميرا (ينتهي بـ /web).': ['On any device on the same network open the link shown on the camera phone (ends with /web).', 'Sur tout appareil du même réseau, ouvrez le lien affiché sur le téléphone caméra (finit par /web).', 'Aynı ağdaki herhangi bir cihazda kamera telefonunda görünen bağlantıyı açın (/web ile biter).', 'اسی نیٹ ورک کے کسی بھی ڈیوائس پر کیمرہ فون پر دکھایا گیا لنک کھولیں (/web پر ختم)۔'],
  'اقبل التحذير': ['Accept the warning', 'Acceptez l\'avertissement', 'Uyarıyı kabul edin', 'انتباہ قبول کریں'],
  'قد يعرض المتصفح تحذير شهادة لأن الاتصال محلي. اختر المتابعة.': ['The browser may show a certificate warning because the link is local. Choose to continue.', 'Le navigateur peut afficher un avertissement de certificat car le lien est local. Choisissez de continuer.', 'Bağlantı yerel olduğu için tarayıcı sertifika uyarısı gösterebilir. Devam edin.', 'لنک مقامی ہونے کی وجہ سے براؤزر سرٹیفکیٹ کی وارننگ دکھا سکتا ہے۔ جاری رکھیں۔'],
  'اكتب الرمز': ['Enter the code', 'Saisissez le code', 'Kodu yazın', 'کوڈ لکھیں'],
  'اكتب رمز المشاهدة فقط لتعرض البث بلا تحكم.': ['Enter the view‑only code to watch without control.', 'Saisissez le code lecture seule pour regarder sans contrôle.', 'Kontrolsüz izlemek için yalnızca izleme kodunu yazın.', 'بغیر کنٹرول کے دیکھنے کے لیے صرف دیکھنے کا کوڈ لکھیں۔'],
  'سجل الدخول': ['Access log', 'Journal d\'accès', 'Erişim günlüğü', 'رسائی لاگ'],
  'سجل الدخول لصاحب الرمز الأساسي فقط': ['The access log is for the main PIN holder only', 'Le journal est réservé au détenteur du PIN principal', 'Erişim günlüğü yalnızca ana PIN sahibi içindir', 'رسائی لاگ صرف اصل PIN والے کے لیے ہے'],
  'سجّل الدخول': ['Access log', 'Journal d\'accès', 'Erişim günlüğü', 'رسائی لاگ'],
  'شاهد': ['Watch', 'Regarder', 'İzle', 'دیکھیں'],
  'افتح الكاميرا الآن': ['Open the camera now', 'Ouvrir la caméra maintenant', 'Kamerayı şimdi aç', 'ابھی کیمرہ کھولیں'],
  'أضف كاميرا': ['Add a camera', 'Ajouter une caméra', 'Kamera ekle', 'کیمرہ شامل کریں'],
  'امسح رمز QR من الكاميرا': ['Scan the QR code from the camera', 'Scannez le code QR de la caméra', 'Kameradaki QR kodunu tarayın', 'کیمرے سے QR کوڈ اسکین کریں'],
  'حل المشاكل وشرح الاستخدام': ['Fix problems and learn how to use', 'Résoudre les problèmes et mode d\'emploi', 'Sorunları çözün ve kullanımı öğrenin', 'مسائل حل کریں اور استعمال سیکھیں'],
  'الوضع المتقدم': ['Advanced mode', 'Mode avancé', 'Gelişmiş mod', 'ایڈوانسڈ موڈ'],
  'لا توجد كاميرا محفوظة — أضف واحدة أولاً': ['No saved camera — add one first', 'Aucune caméra enregistrée — ajoutez-en une', 'Kayıtlı kamera yok — önce bir tane ekleyin', 'کوئی محفوظ کیمرہ نہیں — پہلے ایک شامل کریں'],
  'الواجهة وإمكانية الوصول': ['Interface & accessibility', 'Interface et accessibilité', 'Arayüz ve erişilebilirlik', 'انٹرفیس اور رسائی'],
  'واجهة مبسّطة (3 أزرار)': ['Simple interface (3 buttons)', 'Interface simple (3 boutons)', 'Basit arayüz (3 düğme)', 'آسان انٹرفیس (3 بٹن)'],
  'اللغة': ['Language', 'Langue', 'Dil', 'زبان'],
  'حجم الخط': ['Text size', 'Taille du texte', 'Yazı boyutu', 'ٹیکسٹ سائز'],
  'عادي': ['Normal', 'Normal', 'Normal', 'عام'],
  'كبير': ['Large', 'Grand', 'Büyük', 'بڑا'],
  'كبير جداً': ['Extra large', 'Très grand', 'Çok büyük', 'بہت بڑا'],
  'تباين عالٍ': ['High contrast', 'Contraste élevé', 'Yüksek kontrast', 'زیادہ کنٹراسٹ'],
  'قراءة التنبيهات بصوت عالٍ': ['Read alerts aloud', 'Lire les alertes à voix haute', 'Uyarıları sesli oku', 'الرٹس بلند آواز میں پڑھیں'],
  'قفل التطبيق': ['App lock', 'Verrouillage de l\'app', 'Uygulama kilidi', 'ایپ لاک'],
  'قفل التطبيق (بصمة / وجه / رمز)': ['App lock (fingerprint / face / code)', 'Verrouillage (empreinte / visage / code)', 'Uygulama kilidi (parmak izi / yüz / kod)', 'ایپ لاک (فنگر پرنٹ / چہرہ / کوڈ)'],
  'تعيين رمز القفل': ['Set the lock code', 'Définir le code de verrouillage', 'Kilit kodunu belirle', 'لاک کوڈ مقرر کریں'],
  'رمز من 4 إلى 6 أرقام': ['A code of 4 to 6 digits', 'Un code de 4 à 6 chiffres', '4 ila 6 haneli kod', '4 سے 6 ہندسوں کا کوڈ'],
  'أتمتة (اختصارات iOS)': ['Automation (iOS Shortcuts)', 'Automatisation (Raccourcis iOS)', 'Otomasyon (iOS Kestirmeler)', 'آٹومیشن (iOS شارٹ کٹس)'],
  'تفعيل رابط الأتمتة (المنفذ 8082، غير مشفّر)': ['Enable the automation link (port 8082, unencrypted)', 'Activer le lien d\'automatisation (port 8082, non chiffré)', 'Otomasyon bağlantısını etkinleştir (port 8082, şifresiz)', 'آٹومیشن لنک فعال کریں (پورٹ 8082، غیر خفیہ)'],
  'أنا في المنزل (إيقاف الكشف)': ['I\'m at home (pause detection)', 'Je suis à la maison (pause détection)', 'Evdeyim (algılamayı duraklat)', 'میں گھر پر ہوں (شناخت روکیں)'],
  'ساعتان': ['2 hours', '2 heures', '2 saat', '2 گھنٹے'],
  '8 ساعات': ['8 hours', '8 heures', '8 saat', '8 گھنٹے'],
  'حتى أوقفه': ['Until I turn it off', 'Jusqu\'à désactivation', 'Ben kapatana kadar', 'جب تک بند نہ کروں'],
  'رعاية كبار السن: تنبيه إن لم تُرصد حركة': ['Elder care: alert if no movement', 'Seniors : alerte sans mouvement', 'Yaşlı bakımı: hareket yoksa uyar', 'بزرگوں کی دیکھ بھال: حرکت نہ ہو تو الرٹ'],
  '2 س': ['2 h', '2 h', '2 sa', '2 گھنٹے'],
  '4 س': ['4 h', '4 h', '4 sa', '4 گھنٹے'],
  '8 س': ['8 h', '8 h', '8 sa', '8 گھنٹے'],
  '12 س': ['12 h', '12 h', '12 sa', '12 گھنٹے'],
  'تُسجَّل كل مشاهدة مع التاريخ والجهاز': ['Every viewing is logged with date and device', 'Chaque visionnage est enregistré avec date et appareil', 'Her izleme tarih ve cihazla kaydedilir', 'ہر مشاہدہ تاریخ اور ڈیوائس کے ساتھ درج ہوتا ہے'],
  'لا توجد حركة منذ فترة طويلة — تحقق من الشخص': ['No movement for a long time — check on the person', 'Aucun mouvement depuis longtemps — vérifiez la personne', 'Uzun süredir hareket yok — kişiyi kontrol edin', 'کافی دیر سے کوئی حرکت نہیں — فرد کو دیکھیں'],
  'حيوان أليف': ['Pet', 'Animal de compagnie', 'Evcil hayvan', 'پالتو جانور'],
  'مشاركة': ['Share', 'Partager', 'Paylaş', 'شیئر کریں'],
  'عنوان Tailscale': ['Tailscale address', 'Adresse Tailscale', 'Tailscale adresi', 'Tailscale ایڈریس'],
};

bool homeSel(int home, int v) {
  if (v == 0) return home == 0;
  if (v == -1) return home == -1;
  return home > 0 && (v == 2 ? home <= 2 : home > 2);
}

Future<void> shareBytes(Uint8List b, String name) async {
  try {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(b);
    await Share.shareXFiles([XFile(f.path)]);
  } catch (_) {}
}
