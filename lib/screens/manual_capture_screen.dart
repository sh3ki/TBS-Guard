import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:provider/provider.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../providers/auth_provider.dart';
import '../services/api_service.dart';

class ManualCaptureScreen extends StatefulWidget {
  const ManualCaptureScreen({super.key, required this.queueEntryId, required this.plateNo});

  final int queueEntryId;
  final String plateNo;

  @override
  State<ManualCaptureScreen> createState() => _ManualCaptureScreenState();
}

class _ManualCaptureScreenState extends State<ManualCaptureScreen> {
  CameraController? _controller;
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  FlashMode _flashMode = FlashMode.off;
  double _zoom = 1;
  double _maxZoom = 1;
  int? _tiltRotationAngle;
  bool _initializing = true;
  bool _capturing = false;
  bool _checkingRequest = false;
  bool _requestInvalidated = false;
  Timer? _requestStatusTimer;
  String? _error;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    _startOrientationTracking();
    _initializeCamera();
    _verifyManualRequest();
    _requestStatusTimer = Timer.periodic(const Duration(seconds: 3), (_) => _verifyManualRequest());
  }

  @override
  void dispose() {
    _accelerometerSubscription?.cancel();
    _requestStatusTimer?.cancel();
    _controller?.dispose();
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    super.dispose();
  }

  Future<void> _verifyManualRequest() async {
    if (_checkingRequest || _requestInvalidated || !mounted) return;
    _checkingRequest = true;
    try {
      final response = await ApiService.get('/guard/queue/display', token: context.read<AuthProvider>().user?.token);
      if (!mounted || !response.isSuccessCode) return;
      final data = response.data['data'];
      final pending = data is Map && data['manual_capture'] is Map ? Map<String, dynamic>.from(data['manual_capture'] as Map) : null;
      final pendingId = int.tryParse('${pending?['id'] ?? ''}');
      if (pendingId == widget.queueEntryId) return;

      _requestInvalidated = true;
      await _showMessage('Manual capture cancelled', 'This plate is no longer in the active queue.');
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      // Keep the capture screen open during temporary network failures.
    } finally {
      _checkingRequest = false;
    }
  }

  void _startOrientationTracking() {
    _accelerometerSubscription = accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen((event) {
      int? next;
      if (event.x.abs() > event.y.abs() && event.x.abs() > 6) next = event.x < 0 ? 90 : -90;
      if (next != _tiltRotationAngle && mounted) setState(() => _tiltRotationAngle = next);
    });
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      final camera = cameras.firstWhere((item) => item.lensDirection == CameraLensDirection.back, orElse: () => cameras.first);
      final controller = CameraController(camera, ResolutionPreset.high, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await controller.initialize();
      try {
        await controller.setFlashMode(_flashMode);
        await controller.setFocusMode(FocusMode.auto);
        await controller.setExposureMode(ExposureMode.auto);
      } catch (_) {}
      _maxZoom = await controller.getMaxZoomLevel();
      if (!mounted) { await controller.dispose(); return; }
      setState(() { _controller = controller; _initializing = false; });
    } catch (_) {
      if (mounted) setState(() { _initializing = false; _error = 'Camera could not be opened. Check camera permission.'; });
    }
  }

  Future<void> _cycleFlash() async {
    final controller = _controller;
    if (controller == null) return;
    _flashMode = _flashMode == FlashMode.off ? FlashMode.torch : _flashMode == FlashMode.torch ? FlashMode.auto : FlashMode.off;
    try { await controller.setFlashMode(_flashMode); } catch (_) { _flashMode = FlashMode.off; try { await controller.setFlashMode(FlashMode.off); } catch (_) {} }
    if (mounted) setState(() {});
  }

  Future<void> _setZoom(double value) async {
    final controller = _controller;
    if (controller == null) return;
    _zoom = value.clamp(1, _maxZoom);
    await controller.setZoomLevel(_zoom);
    if (mounted) setState(() {});
  }

  Widget _zoomPreset(double value) {
    final enabled = value <= _maxZoom + .05;
    final active = (_zoom - value).abs() < .08;
    return GestureDetector(
      onTap: enabled ? () => _setZoom(value.clamp(1, _maxZoom).toDouble()) : null,
      child: Container(margin: const EdgeInsets.symmetric(horizontal: 7), padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10), decoration: BoxDecoration(color: active ? Colors.grey.shade800 : Colors.transparent, borderRadius: BorderRadius.circular(22)), child: Text('${value.toStringAsFixed(0)}x', style: TextStyle(color: !enabled ? Colors.white38 : active ? Colors.yellow : Colors.white, fontWeight: FontWeight.bold, fontSize: 14))),
    );
  }

  Future<XFile> _rotateCapture(XFile source) async {
    final orientation = _controller!.value.deviceOrientation;
    final fallback = orientation == DeviceOrientation.landscapeLeft ? 90 : orientation == DeviceOrientation.landscapeRight ? -90 : 0;
    final angle = _tiltRotationAngle ?? fallback;
    if (angle == 0) return source;
    final decoded = img.decodeImage(await File(source.path).readAsBytes());
    if (decoded == null) return source;
    final rotated = img.copyRotate(decoded, angle: angle);
    final path = '${source.path}_oriented.jpg';
    await File(path).writeAsBytes(img.encodeJpg(rotated, quality: 95));
    return XFile(path);
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _capturing) return;
    setState(() => _capturing = true);
    try {
      final image = await _rotateCapture(await controller.takePicture());
      if (!mounted) return;
      setState(() => _capturing = false);
      await _showPreview(image);
    } catch (_) {
      if (mounted) { setState(() => _capturing = false); _showMessage('Capture failed', 'Please try capturing the plate again.'); }
    }
  }

  Future<void> _showPreview(XFile image) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ClipRRect(borderRadius: BorderRadius.circular(8), child: ConstrainedBox(constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .55), child: Image.file(File(image.path), fit: BoxFit.contain))),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: _capturing ? null : () { Navigator.pop(dialogContext); }, child: const Text('RETAKE'))),
              const SizedBox(width: 10),
              Expanded(child: ElevatedButton(onPressed: _capturing ? null : () async { Navigator.pop(dialogContext); await _submit(image); }, style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade400, foregroundColor: Colors.white), child: const Text('SUBMIT'))),
            ]),
          ]),
        ),
      ),
    );
  }

  Future<void> _submit(XFile image) async {
    setState(() => _capturing = true);
    try {
      final response = await ApiService.postMultipart('/guard/manual-capture', file: File(image.path), token: context.read<AuthProvider>().user?.token, fields: {'queue_entry_id': '${widget.queueEntryId}', 'user_id': '${context.read<AuthProvider>().user?.id ?? 0}'});
      if (!mounted) return;
      if (!response.isSuccessCode || response.data['success'] != true) { await _showMessage('Submit failed', ApiService.extractMessage(response.data)); return; }
      await _showMessage('Truck is Now Serving!', 'Plate ${widget.plateNo} was moved to Serving.', success: true);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) await _showMessage('Submit failed', 'Please try again.');
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  Future<void> _showMessage(String title, String message, {bool success = false}) async {
    if (!mounted) return;
    await showDialog<void>(context: context, barrierDismissible: false, builder: (dialogContext) => AlertDialog(backgroundColor: success ? const Color(0xFF16A34A) : const Color(0xFFDC2626), icon: Icon(success ? Icons.check_circle : Icons.error, color: Colors.white, size: 54), title: Text(title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), content: Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)), actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('CLOSE', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)))]));
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return WillPopScope(
      onWillPop: () async => false,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(automaticallyImplyLeading: false, backgroundColor: Colors.black, elevation: 0, title: Text('PICTURE PLATE ${widget.plateNo}', style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)), actions: [Padding(padding: const EdgeInsets.all(10), child: GestureDetector(onTap: _cycleFlash, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: Colors.grey.shade800, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white24)), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(_flashMode == FlashMode.off ? Icons.flash_off : _flashMode == FlashMode.torch ? Icons.flash_on : Icons.flash_auto, color: Colors.white, size: 18), const SizedBox(width: 6), Text(_flashMode == FlashMode.off ? 'Flash Off' : _flashMode == FlashMode.torch ? 'Flash On' : 'Auto', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12))]))))]),
        body: _initializing ? const Center(child: CircularProgressIndicator(color: Colors.white)) : _error != null ? Center(child: Text(_error!, style: const TextStyle(color: Colors.white))) : Stack(fit: StackFit.expand, children: [
          if (controller != null) Positioned(top: 0, left: 0, right: 0, bottom: 168, child: ClipRect(child: FittedBox(fit: BoxFit.cover, child: SizedBox(width: controller.value.previewSize?.height ?? 1, height: controller.value.previewSize?.width ?? 1, child: CameraPreview(controller))))),
          Positioned(top: 12, right: 12, child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), decoration: BoxDecoration(color: Colors.black.withOpacity(.65), borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.white24)), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(_tiltRotationAngle == 90 ? Icons.rotate_left : _tiltRotationAngle == -90 ? Icons.rotate_right : Icons.screen_rotation_alt, color: Colors.white, size: 18), const SizedBox(width: 6), Text(_tiltRotationAngle == 90 ? 'Rotate: LEFT' : _tiltRotationAngle == -90 ? 'Rotate: RIGHT' : 'Rotate: DEFAULT', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600))]))),
          Positioned(bottom: 100, left: 0, right: 0, child: Center(child: Row(mainAxisSize: MainAxisSize.min, children: [_zoomPreset(1), _zoomPreset(2), _zoomPreset(5), _zoomPreset(10)]))),
          Positioned(bottom: 18, left: 0, right: 0, child: Center(child: GestureDetector(onTap: _capturing ? null : _capture, child: Container(width: 86, height: 86, decoration: BoxDecoration(shape: BoxShape.circle, color: _capturing ? Colors.grey : Colors.red.shade400, border: Border.all(color: Colors.white, width: 4)), child: _capturing ? const Center(child: SizedBox(width: 36, height: 36, child: CircularProgressIndicator(strokeWidth: 3, valueColor: AlwaysStoppedAnimation<Color>(Colors.white)))) : const Icon(Icons.camera_alt, color: Colors.white, size: 40))))),
        ]),
      ),
    );
  }
}
