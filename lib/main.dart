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
const Map<String, dynamic> kPcConfig = {
  'sdpSemantics': 'unified-plan',
  'iceServers': <Map<String, dynamic>>[], // LAN only
};

const MethodChannel _svc = MethodChannel('lancam/service');

void main() => runApp(const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Home(),
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
      if (body.startsWith('LAN Cam')) found.add(ip);
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
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton.filled(
            onPressed: onTap,
            icon: Icon(icon),
            style: IconButton.styleFrom(
              backgroundColor:
                  active ? Colors.redAccent : (dark ? Colors.white24 : null),
              foregroundColor: (active || dark) ? Colors.white : null,
            ),
          ),
          Text(label,
              style: TextStyle(fontSize: 11, color: dark ? Colors.white : null)),
        ],
      );
}

/// In-app numeric keypad WITH a dot key (works on every phone/locale).
class Keypad extends StatelessWidget {
  const Keypad({super.key, required this.onKey, required this.onBack});
  final void Function(String) onKey;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '.', '0', '⌫'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: 2.4,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        children: [
          for (final k in keys)
            FilledButton.tonal(
              onPressed: () => k == '⌫' ? onBack() : onKey(k),
              child: Text(k, style: const TextStyle(fontSize: 24)),
            ),
        ],
      ),
    );
  }
}

class Home extends StatelessWidget {
  const Home({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('LAN Cam')),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            FilledButton.icon(
              icon: const Icon(Icons.videocam),
              label: const Text('كاميرا (بث)'),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const CameraPage())),
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.monitor),
              label: const Text('مشاهدة'),
              onPressed: () => Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const ViewerPage())),
            ),
          ]),
        ),
      );
}

// ───────────────────────── Camera (broadcaster) ─────────────────────────
class CameraPage extends StatefulWidget {
  const CameraPage({super.key});
  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> {
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

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable(); // keep the screen on while broadcasting
    _start();
  }

  Future<void> _start() async {
    final s = await loadSettings();
    _pin = (s['campin'] as String?) ?? _newPin();
    await saveSettings({'campin': _pin});

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
    WakelockPlus.disable();
    if (Platform.isAndroid) {
      _svc.invokeMethod('stop').catchError((_) {});
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
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('وضع الكاميرا'), toolbarHeight: 44),
        body: SafeArea(
          child: Row(children: [
            Expanded(child: RTCVideoView(_local)),
            SizedBox(
              width: 250,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    SelectableText('$_ip:$kPort',
                        style: const TextStyle(fontSize: 20)),
                    const SizedBox(height: 8),
                    const Text('رمز الدخول (PIN)'),
                    Text(_pin,
                        style: const TextStyle(
                            fontSize: 30,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 4)),
                    TextButton.icon(
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('رمز جديد'),
                      onPressed: () {
                        setState(() => _pin = _newPin());
                        saveSettings({'campin': _pin});
                      },
                    ),
                    Text('الحالة: $_status'),
                    const SizedBox(height: 8),
                    if (Platform.isAndroid)
                      FilledButton.icon(
                        icon: Icon(_recording
                            ? Icons.stop
                            : Icons.fiber_manual_record),
                        label: Text(_recording ? 'إيقاف التسجيل' : 'تسجيل'),
                        onPressed: () async {
                          await _toggleRec();
                          _sendRec();
                        },
                      )
                    else
                      const Text('التسجيل متاح على Android فقط',
                          textAlign: TextAlign.center),
                    if (Platform.isAndroid)
                      TextButton.icon(
                        icon: const Icon(Icons.battery_saver, size: 18),
                        label: const Text('السماح بالعمل بالخلفية'),
                        onPressed: () => _svc.invokeMethod('battery'),
                      ),
                  ],
                ),
              ),
            ),
          ]),
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
      setState(() => _status = 'فشل الاتصال: $e');
    }
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

  @override
  Widget build(BuildContext context) {
    if (_wide) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(children: [
          Positioned.fill(child: RTCVideoView(_remote)),
          Positioned(
            top: 8,
            left: 12,
            child: SafeArea(
              child: Text(_status, style: const TextStyle(color: Colors.white70)),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 8,
            child: SafeArea(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 60),
                padding: const EdgeInsets.symmetric(vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(16),
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
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Row(children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: _ipCtl,
                keyboardType: TextInputType.none, // we use our own keypad
                onTap: () => setState(() => _pinActive = false),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
                ],
                decoration: const InputDecoration(
                  labelText: 'IP الكاميرا',
                  hintText: '192.168.1.20',
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: TextField(
                controller: _pinCtl,
                keyboardType: TextInputType.none,
                onTap: () => setState(() => _pinActive = true),
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'PIN'),
              ),
            ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: _scanning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.search),
                label: const Text('بحث تلقائي'),
                onPressed: _scanning ? null : _scan,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.play_arrow),
                label: const Text('اتصال'),
                onPressed: _connect,
              ),
            ),
          ]),
        ),
        if (_found.isNotEmpty)
          Wrap(
            spacing: 8,
            children: [
              for (final ip in _found)
                ActionChip(
                  avatar: const Icon(Icons.videocam, size: 18),
                  label: Text(ip),
                  onPressed: () => setState(() {
                    _ipCtl.text = ip;
                    _pinActive = true;
                  }),
                ),
            ],
          ),
        Text(_status),
        Expanded(child: RTCVideoView(_remote)),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: _controls(dark: false),
        ),
        if (!_isConnected) Keypad(onKey: _key, onBack: _back),
      ]),
    );
  }
}
