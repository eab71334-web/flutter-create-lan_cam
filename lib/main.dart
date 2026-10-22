import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

const int kPort = 8080;
const Map<String, dynamic> kPcConfig = {
  'sdpSemantics': 'unified-plan',
  'iceServers': <Map<String, dynamic>>[], // LAN only
};

void main() => runApp(const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Home(),
    ));

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
              style: TextStyle(fontSize: 12, color: dark ? Colors.white : null)),
        ],
      );
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
  String _status = 'بانتظار المشاهد';
  bool _recording = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
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

    for (final i in await NetworkInterface.list(type: InternetAddressType.IPv4)) {
      if (!i.addresses.first.isLoopback) {
        _ip = i.addresses.first.address;
        break;
      }
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
      _ws = ws;
      ws.listen((m) async {
        final d = jsonDecode(m as String);
        switch (d['type']) {
          case 'offer':
            await _answer(ws, d['sdp'] as String);
            _sendRec();
            break;
          case 'record':
            await _setRec(d['on'] == true);
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

  void _sendRec({bool ok = true}) {
    try {
      _ws?.add(jsonEncode({'type': 'rec', 'on': _recording, 'ok': ok}));
    } catch (_) {}
  }

  /// Called from the viewer (remote command).
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
              width: 230,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    SelectableText('$_ip:$kPort',
                        style: const TextStyle(fontSize: 20)),
                    const SizedBox(height: 6),
                    Text('الحالة: $_status'),
                    const SizedBox(height: 12),
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
  RTCPeerConnection? _pc;
  WebSocket? _ws;
  MediaStream? _mic;
  MediaStreamTrack? _micTrack;
  String _status = '';
  bool _wide = false;
  bool _autoWideDone = false;
  bool _talking = false;
  bool _muted = false;
  bool _remoteRec = false;

  @override
  void initState() {
    super.initState();
    _remote.initialize();
  }

  void _snack(String m) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(m)));
    }
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
    try {
      setState(() => _status = 'جاري الاتصال...');
      await _pc?.close();
      _ws?.close();
      final ws = _ws =
          await WebSocket.connect('ws://${_ipCtl.text.trim()}:$kPort')
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
        setState(() => _status = s.name.replaceAll('RTCPeerConnectionState', ''));
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateConnected &&
            !_autoWideDone) {
          _autoWideDone = true;
          _setWide(true); // go wide automatically once connected
        }
      };
      ws.listen((m) async {
        final d = jsonDecode(m as String);
        if (d['type'] == 'answer') {
          await pc.setRemoteDescription(
              RTCSessionDescription(d['sdp'] as String, 'answer'));
        } else if (d['type'] == 'rec') {
          if (mounted) setState(() => _remoteRec = d['on'] == true);
          if (d['ok'] == false) {
            _snack('التسجيل غير مدعوم على جهاز الكاميرا (Android فقط)');
          }
        }
      }, onDone: () {
        if (mounted) setState(() => _status = 'انقطع الاتصال');
      });

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      await waitIceGathered(pc);
      final l = await pc.getLocalDescription();
      ws.add(jsonEncode({'type': 'offer', 'sdp': l!.sdp}));
    } catch (e) {
      setState(() => _status = 'فشل الاتصال: $e');
    }
  }

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

  /// Recording happens on the camera phone (Android), commanded from here.
  void _toggleRec() {
    if (_ws == null) {
      _snack('اتصل بالكاميرا أولاً');
      return;
    }
    _ws!.add(jsonEncode({'type': 'record', 'on': !_remoteRec}));
  }

  @override
  void dispose() {
    _pc?.close();
    _ws?.close();
    _micTrack?.stop();
    _mic?.dispose();
    _remote.dispose();
    _ipCtl.dispose();
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
                margin: const EdgeInsets.symmetric(horizontal: 80),
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
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _ipCtl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
                ],
                decoration: const InputDecoration(
                    labelText: 'IP الكاميرا مثل 192.168.1.20'),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _connect, child: const Text('اتصال')),
          ]),
        ),
        Text(_status),
        Expanded(child: RTCVideoView(_remote)),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: _controls(dark: false),
        ),
      ]),
    );
  }
}
