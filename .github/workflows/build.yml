import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

const int kPort = 8080;
const int kWakePort = 8081; // standby listener (camera app closed)
const Map<String, dynamic> kPcConfig = {
  'sdpSemantics': 'unified-plan',
  'iceServers': <Map<String, dynamic>>[], // LAN only
};

const MethodChannel _svc = MethodChannel('lancam/service');

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
  Timer? _diagTimer;

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
    if (Platform.isAndroid) {
      try {
        await _svc.invokeMethod('config', {'always': _always, 'pin': _pin});
      } catch (_) {}
    }

    await _landscape(); // wide capture
    await Future.delayed(const Duration(milliseconds: 600));
    await [Permission.camera, Permission.microphone].request();
    await _local.initialize();
    try {
      _stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': {
          'mandatory': {
            'minWidth': '1280',
            'minHeight': '720',
            'minFrameRate': '24'
          },
          'facingMode': 'environment',
          'optional': [],
        },
      });
    } catch (_) {
      _stream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': {'facingMode': 'environment'},
      });
    }
    _local.srcObject = _stream;
    _ip = await localIp() ?? '...';

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
      final ws = await WebSocketTransformer.upgrade(req);
      var authed = false;
      ws.listen((m) async {
        final d = jsonDecode(m as String);
        switch (d['type']) {
          case 'offer':
            if ((d['pin'] ?? '') != _pin) {
              ws.add(jsonEncode({'type': 'denied'}));
              await ws.close();
              return;
            }
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
        }
      });
    });
    if (mounted) setState(() {});
    _refreshDiag();
    _diagTimer =
        Timer.periodic(const Duration(seconds: 3), (_) => _refreshDiag());

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
    };
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    final ans = await pc.createAnswer();
    await pc.setLocalDescription(ans);
    await waitIceGathered(pc);
    final l = await pc.getLocalDescription();
    ws.add(jsonEncode({'type': 'answer', 'sdp': l!.sdp}));
  }

  /// Remote controls from the viewer: switch camera / flashlight.
  Future<void> _cmd(Map<String, dynamic> d) async {
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
      if (mounted) setState(() => _recording = false);
      return;
    }
    final dir = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final path = '${dir.path}/cam_${DateTime.now().millisecondsSinceEpoch}.mp4';
    _rec = MediaRecorder();
    await _rec!.start(path,
        videoTrack: _stream!.getVideoTracks().first,
        audioChannel: RecorderAudioChannel.INPUT);
    if (mounted) setState(() => _recording = true);
  }

  @override
  void dispose() {
    CameraPage.active = false;
    _diagTimer?.cancel();
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
      if (mounted && m != null) setState(() => _diag = m);
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
            const SizedBox(height: 12),
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
  const ViewerPage({super.key});
  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
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

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _remote.initialize();
    loadSettings().then((s) {
      if (!mounted) return;
      _ipCtl.text = (s['ip'] as String?) ?? '';
      _pinCtl.text = (s['pin'] as String?) ?? '';
    });
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

  Future<void> _connect() async {
    FocusScope.of(context).unfocus();
    final ip = _ipCtl.text.trim();
    if (ip.isEmpty) {
      _snack('اكتب IP الكاميرا أو اضغط بحث');
      return;
    }
    saveSettings({'ip': ip, 'pin': _pinCtl.text});
    _denied = false;
    try {
      setState(() => _status = 'جاري الاتصال...');
      if (!await _portOpen(ip, kPort)) {
        // camera app is closed: wake it (standby listener on the camera phone)
        setState(() => _status = 'الكاميرا مغلقة — جاري إيقاظها...');
        final woke = await _wakeCamera(ip, _pinCtl.text);
        if (woke != 'ok') throw 'wake-$woke';
        var up = false;
        for (var i = 0; i < 25 && !up; i++) {
          await Future.delayed(const Duration(seconds: 1));
          up = await _portOpen(ip, kPort);
        }
        if (!up) throw 'wake-timeout';
        if (mounted) setState(() => _status = 'جاري الاتصال...');
      }
      await _pc?.close();
      _ws?.close();
      final ws = _ws = await WebSocket.connect('ws://$ip:$kPort')
          .timeout(const Duration(seconds: 5));

      // Microphone (talk-back to the camera). Starts muted.
      if (_micTrack == null) {
        try {
          _mic = await navigator.mediaDevices
              .getUserMedia({'audio': true, 'video': false});
          _micTrack = _mic!.getAudioTracks().first;
          _micTrack!.enabled = false;
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
        }
      };
      pc.onConnectionState = (s) {
        if (!mounted) return;
        setState(() {
          _status = s.name.replaceAll('RTCPeerConnectionState', '');
          _isConnected =
              s == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
        });
        if (_isConnected && !_autoWideDone) {
          _autoWideDone = true;
          _setWide(true); // go wide automatically once connected
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
          case 'denied':
            _denied = true;
            if (mounted) setState(() => _status = 'PIN غير صحيح');
            _snack('PIN غير صحيح');
            await pc.close();
            _ws?.close();
            break;
        }
      }, onDone: () {
        if (mounted && !_denied) setState(() => _status = 'انقطع الاتصال');
      });

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await waitIceGathered(pc);
      final l = await pc.getLocalDescription();
      ws.add(jsonEncode({'type': 'offer', 'sdp': l!.sdp, 'pin': _pinCtl.text}));
    } catch (e) {
      if (mounted) setState(() => _status = _friendly(e));
    }
  }

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

  Widget _controls({required bool dark}) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
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
          Positioned.fill(child: RTCVideoView(_remote)),
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
                child: _controls(dark: true),
              ),
            ),
          ),
        ]),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('وضع المشاهدة')),
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
                  label: const Text('بحث تلقائي'),
                  onPressed: _scanning ? null : _scan,
                ),
              ),
              const SizedBox(width: 10),
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
                RTCVideoView(_remote),
                if (_remote.srcObject == null)
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
          child: _controls(dark: false),
        ),
        if (!_isConnected)
          SafeArea(
            top: false,
            child: Keypad(onKey: _key, onBack: _back),
          ),
      ]),
    );
  }
}
