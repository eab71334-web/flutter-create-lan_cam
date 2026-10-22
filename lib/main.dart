import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

const int kPort = 8080;
const Map<String, dynamic> kPcConfig = {
  'sdpSemantics': 'unified-plan',
  'iceServers': <Map<String, dynamic>>[], // LAN only, no STUN needed
};

void main() => runApp(const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Home(),
    ));

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
    await [Permission.camera, Permission.microphone].request();
    await _local.initialize();
    _stream = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': {'facingMode': 'environment'},
    });
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
      ws.listen((m) async {
        final d = jsonDecode(m as String);
        if (d['type'] == 'offer') await _answer(ws, d['sdp'] as String);
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
      if (mounted) setState(() => _status = s.name.replaceAll('RTCPeerConnectionState', ''));
    };
    await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    final ans = await pc.createAnswer();
    await pc.setLocalDescription(ans);
    await waitIceGathered(pc);
    final l = await pc.getLocalDescription();
    ws.add(jsonEncode({'type': 'answer', 'sdp': l!.sdp}));
  }

  Future<void> _toggleRec() async {
    if (!Platform.isAndroid) return; // flutter_webrtc recorder: Android only
    if (_recording) {
      await _rec?.stop();
      setState(() => _recording = false);
      return;
    }
    final dir = await getExternalStorageDirectory() ??
        await getApplicationDocumentsDirectory();
    final path =
        '${dir.path}/cam_${DateTime.now().millisecondsSinceEpoch}.mp4';
    _rec = MediaRecorder();
    await _rec!.start(path,
        videoTrack: _stream!.getVideoTracks().first,
        audioChannel: RecorderAudioChannel.INPUT);
    setState(() => _recording = true);
  }

  @override
  void dispose() {
    _rec?.stop();
    _pc?.close();
    _server?.close(force: true);
    _stream?.dispose();
    _local.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('وضع الكاميرا')),
        body: Column(children: [
          Expanded(child: RTCVideoView(_local, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              SelectableText('العنوان: $_ip:$kPort',
                  style: const TextStyle(fontSize: 20)),
              Text('الحالة: $_status'),
              if (Platform.isAndroid)
                FilledButton.icon(
                  icon: Icon(_recording ? Icons.stop : Icons.fiber_manual_record),
                  label: Text(_recording ? 'إيقاف التسجيل' : 'تسجيل'),
                  onPressed: _toggleRec,
                )
              else
                const Text('التسجيل متاح على Android فقط'),
            ]),
          ),
        ]),
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
  String _status = '';

  @override
  void initState() {
    super.initState();
    _remote.initialize();
  }

  Future<void> _connect() async {
    try {
      setState(() => _status = 'جاري الاتصال...');
      await _pc?.close();
      _ws?.close();
      final ws = _ws = await WebSocket.connect('ws://${_ipCtl.text.trim()}:$kPort')
          .timeout(const Duration(seconds: 5));
      final pc = _pc = await createPeerConnection(kPcConfig);
      for (final k in [RTCRtpMediaType.RTCRtpMediaTypeVideo, RTCRtpMediaType.RTCRtpMediaTypeAudio]) {
        await pc.addTransceiver(
          kind: k,
          init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
        );
      }
      pc.onTrack = (e) {
        if (e.streams.isNotEmpty) {
          setState(() => _remote.srcObject = e.streams.first);
        }
      };
      pc.onConnectionState = (s) {
        if (mounted) setState(() => _status = s.name.replaceAll('RTCPeerConnectionState', ''));
      };
      ws.listen((m) async {
        final d = jsonDecode(m as String);
        if (d['type'] == 'answer') {
          await pc.setRemoteDescription(RTCSessionDescription(d['sdp'] as String, 'answer'));
        }
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

  @override
  void dispose() {
    _pc?.close();
    _ws?.close();
    _remote.dispose();
    _ipCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('وضع المشاهدة')),
        body: Column(children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _ipCtl,
                  keyboardType: TextInputType.number,
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
        ]),
      );
}
