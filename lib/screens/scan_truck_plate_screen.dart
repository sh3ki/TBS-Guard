import 'dart:math' as math;
import 'dart:io';
import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:sensors_plus/sensors_plus.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../services/api_service.dart';

const _plateGuideAspectRatio = 2.7 / 1.5;
const _captureMargin = .18;

class ScanTruckPlateScreen extends StatefulWidget {
  const ScanTruckPlateScreen({super.key});
  @override
  State<ScanTruckPlateScreen> createState() => _ScanTruckPlateScreenState();
}

class _ScanTruckPlateScreenState extends State<ScanTruckPlateScreen> {
  // Temporary UI preview flag; disable after the success modal is approved.
  static const bool _testingSuccessModal = false;
  CameraController? _controller;
  bool _initializing = true;
  bool _capturing = false;
  FlashMode _flashMode = FlashMode.off;
  double _zoom = 1;
  double _maxZoom = 1;
  String? _error;
  XFile? _captured;
  StreamSubscription<AccelerometerEvent>? _accelerometerSubscription;
  int? _tiltRotationAngle;
  String _scanAction = 'return';

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    _startOrientationTracking();
    _initializeCamera();
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
      } catch (_) {
        // Some emulators/cameras do not expose every camera control.
      }
      _maxZoom = await controller.getMaxZoomLevel();
      if (!mounted) { await controller.dispose(); return; }
      setState(() { _controller = controller; _initializing = false; });
    } catch (_) {
      if (mounted) setState(() { _initializing = false; _error = 'Camera could not be opened. Check camera permission.'; });
    }
  }

  @override
  void dispose() {
    _accelerometerSubscription?.cancel();
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    _controller?.dispose();
    super.dispose();
  }

  void _startOrientationTracking() {
    _accelerometerSubscription = accelerometerEventStream(samplingPeriod: SensorInterval.uiInterval).listen((event) {
      int? next;
      if (event.x.abs() > event.y.abs() && event.x.abs() > 6) {
        next = event.x < 0 ? 90 : -90;
      }
      if (next != _tiltRotationAngle && mounted) setState(() => _tiltRotationAngle = next);
    });
  }

  Future<void> _cycleFlash() async {
    final controller = _controller;
    if (controller == null) return;
    _flashMode = _flashMode == FlashMode.off ? FlashMode.torch : _flashMode == FlashMode.torch ? FlashMode.auto : FlashMode.off;
    try {
      await controller.setFlashMode(_flashMode);
    } catch (_) {
      _flashMode = FlashMode.off;
      try { await controller.setFlashMode(FlashMode.off); } catch (_) {}
    }
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
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 7),
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 10),
        decoration: BoxDecoration(color: active ? Colors.grey.shade800 : Colors.transparent, borderRadius: BorderRadius.circular(22)),
        child: Text('${value.toStringAsFixed(0)}x', style: TextStyle(color: !enabled ? Colors.white38 : active ? Colors.yellow : Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
      ),
    );
  }

  Widget _actionTab(String label, String value, Color color) {
    final selected = _scanAction == value;
    return GestureDetector(
      onTap: () => setState(() => _scanAction = value),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? color : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : color,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _capturing) return;
    setState(() => _capturing = true);
    try {
      final captured = await controller.takePicture();
      final landscapeTilt = _tiltRotationAngle == 90 || _tiltRotationAngle == -90;
      final oriented = await _rotateCapture(captured);
      final image = await _cropToGuide(oriented);
      if (!mounted) return;
      setState(() { _captured = image; _capturing = false; });
      await _showPreview(image, landscapeTilt: landscapeTilt);
    } catch (_) {
      if (mounted) setState(() => _capturing = false);
      if (mounted) _showMessage('Capture failed', 'Please try capturing the plate again.');
    }
  }

  /// Keeps the entire captured frame, but normalizes its orientation so OCR
  /// receives a readable landscape plate even when the phone is held sideways.
  Future<XFile> _rotateCapture(XFile source) async {
    final deviceOrientation = _controller!.value.deviceOrientation;
    final fallback = deviceOrientation == DeviceOrientation.landscapeLeft ? 90 : deviceOrientation == DeviceOrientation.landscapeRight ? -90 : 0;
    final angle = _tiltRotationAngle ?? fallback;
    if (angle == 0) return source;
    final decoded = img.decodeImage(await File(source.path).readAsBytes());
    if (decoded == null) return source;
    final rotated = img.copyRotate(decoded, angle: angle);
    final path = '${source.path}_oriented.jpg';
    await File(path).writeAsBytes(img.encodeJpg(rotated, quality: 95));
    return XFile(path);
  }

  Future<XFile> _cropToGuide(XFile source) async {
    final decoded = img.decodeImage(await File(source.path).readAsBytes());
    if (decoded == null) return source;

    final sourceAspectRatio = decoded.width / decoded.height;
    int cropWidth;
    int cropHeight;
    if (sourceAspectRatio >= _plateGuideAspectRatio) {
      cropHeight = decoded.height;
      cropWidth = (cropHeight * _plateGuideAspectRatio).round();
    } else {
      cropWidth = decoded.width;
      cropHeight = (cropWidth / _plateGuideAspectRatio).round();
    }
    cropWidth = cropWidth.clamp(1, decoded.width).toInt();
    cropHeight = cropHeight.clamp(1, decoded.height).toInt();
    final cropped = img.copyCrop(
      decoded,
      x: (decoded.width - cropWidth) ~/ 2,
      y: (decoded.height - cropHeight) ~/ 2,
      width: cropWidth,
      height: cropHeight,
    );
    final path = '${source.path}_guide_crop.jpg';
    await File(path).writeAsBytes(img.encodeJpg(cropped, quality: 95));
    return XFile(path);
  }

  Future<void> _showPreview(XFile image, {required bool landscapeTilt}) async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => Dialog(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .55),
                child: AspectRatio(
                  aspectRatio: _plateGuideAspectRatio,
          child: Stack(fit: StackFit.expand, children: [
                    Image.file(File(image.path), fit: BoxFit.cover),
            IgnorePointer(child: CustomPaint(painter: CapturePreviewGuidePainter(landscapeTilt: landscapeTilt, withdrawMode: _scanAction == 'withdraw'))),
                  ]),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: () { Navigator.pop(dialogContext); setState(() => _captured = null); }, child: const Text('RETAKE'))),
              const SizedBox(width: 10),
              Expanded(child: ElevatedButton(
                onPressed: _capturing ? null : () async { Navigator.pop(dialogContext); await _submitImage(image); },
                style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade400, foregroundColor: Colors.white),
                child: const Text('SUBMIT'),
              )),
            ]),
          ]),
        ),
      ),
    );
  }

  Future<void> _submitImage(XFile image) async {
    setState(() => _capturing = true);
    try {
      if (_testingSuccessModal) {
        await _showMessage('This Truck is not in Queue', 'The scanned truck is not currently in the waiting queue.');
        return;
      }
      final file = File(image.path);
      final decoded = img.decodeImage(await file.readAsBytes());
      if (decoded == null || _laplacianVariance(decoded) < 22) {
        await _showMessage('Image is blurred', 'Please retake the image with the plate steady and in focus.');
        return;
      }
      final response = await ApiService.postMultipart(
        '/guard/scan-truck-plate',
        file: file,
        token: context.read<AuthProvider>().user?.token,
        fields: {
          'action': _scanAction,
          'user_id': '${context.read<AuthProvider>().user?.id ?? 0}',
        },
      );
      if (!mounted) return;
      if (response.data['wrong_queue'] == true) {
        await _showMessage('Wrong Queue', ApiService.extractMessage(response.data), backgroundColor: Colors.orange.shade700);
        return;
      }
      if (response.data['not_next_line'] == true) {
        await _showMessage('Not Next in Line', ApiService.extractMessage(response.data), backgroundColor: Colors.orange.shade700);
        return;
      }
      if (!response.isSuccessCode || response.data['success'] != true) {
        await _showMessage('Scan failed', ApiService.extractMessage(response.data));
        return;
      }
      if (response.data['queue_updated'] == true) {
        await _showMessage(
          'Truck is Now Serving!',
          'Plate ${response.data['plate_no'] ?? ''} was moved to Serving.',
          success: true,
        );
      } else {
        await _showMessage('This Truck is not in Queue', 'Detected plate: ${response.data['plate_no'] ?? ''}');
      }
    } catch (_) {
      if (mounted) await _showMessage('Scan failed', 'Please try again with a clearer image.');
    } finally {
      if (mounted) setState(() { _capturing = false; _captured = null; });
    }
  }

  double _laplacianVariance(img.Image source) {
    final gray = img.grayscale(source);
    final samples = <double>[];
    for (var y = 1; y < gray.height - 1; y += 4) {
      for (var x = 1; x < gray.width - 1; x += 4) {
        final center = gray.getPixel(x, y).luminance;
        final value = (gray.getPixel(x - 1, y).luminance + gray.getPixel(x + 1, y).luminance + gray.getPixel(x, y - 1).luminance + gray.getPixel(x, y + 1).luminance - (4 * center)).toDouble();
        samples.add(value);
      }
    }
    if (samples.isEmpty) return 0;
    final mean = samples.reduce((a, b) => a + b) / samples.length;
    return samples.map((v) => math.pow(v - mean, 2).toDouble()).reduce((a, b) => a + b) / samples.length;
  }

  Future<void> _showMessage(String title, String message, {Color? backgroundColor, bool success = false}) async {
    if (!mounted) return;
    final color = backgroundColor ?? (success ? const Color(0xFF16A34A) : const Color(0xFFDC2626));
    final icon = success ? Icons.check_circle : Icons.error;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: color,
        icon: Icon(icon, color: Colors.white, size: 54),
        title: Text(title, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Text(message, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white)),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('CLOSE', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, elevation: 0, title: const Text('SCAN TRUCK PLATE', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)), iconTheme: const IconThemeData(color: Colors.white), actions: [
        Padding(padding: const EdgeInsets.all(10), child: GestureDetector(onTap: _cycleFlash, child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: Colors.grey.shade800, borderRadius: BorderRadius.circular(16), border: Border.all(color: Colors.white24)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_flashMode == FlashMode.off ? Icons.flash_off : _flashMode == FlashMode.torch ? Icons.flash_on : Icons.flash_auto, color: Colors.white, size: 18),
            const SizedBox(width: 6),
            Text(_flashMode == FlashMode.off ? 'Flash Off' : _flashMode == FlashMode.torch ? 'Flash On' : 'Auto', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
          ]),
        )))
      ]),
      body: _initializing ? const Center(child: CircularProgressIndicator(color: Colors.white)) : _error != null ? Center(child: Text(_error!, style: const TextStyle(color: Colors.white))) : Stack(fit: StackFit.expand, children: [
        if (controller != null) Positioned(top: 0, left: 0, right: 0, bottom: 168, child: ClipRect(child: FittedBox(
          fit: BoxFit.cover,
          child: SizedBox(
            width: controller.value.previewSize?.height ?? 1,
            height: controller.value.previewSize?.width ?? 1,
            child: CameraPreview(controller),
          ),
        ))),
        Positioned(top: 0, left: 0, right: 0, bottom: 168, child: IgnorePointer(child: CustomPaint(painter: PlateGuidePainter(landscapeTilt: _tiltRotationAngle == 90 || _tiltRotationAngle == -90, withdrawMode: _scanAction == 'withdraw')))),
        Positioned(
          top: 12,
          left: 12,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(.65),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white24),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              _actionTab('RETURN', 'return', Colors.green),
              _actionTab('WITHDRAW', 'withdraw', Colors.red),
            ]),
          ),
        ),
        Positioned(top: 12, right: 12, child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(color: Colors.black.withOpacity(.65), borderRadius: BorderRadius.circular(14), border: Border.all(color: Colors.white24)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(_tiltRotationAngle == 90 ? Icons.rotate_left : _tiltRotationAngle == -90 ? Icons.rotate_right : Icons.screen_rotation_alt, color: Colors.white, size: 18),
            const SizedBox(width: 6),
            Text(_tiltRotationAngle == 90 ? 'Rotate: LEFT' : _tiltRotationAngle == -90 ? 'Rotate: RIGHT' : 'Rotate: DEFAULT', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
          ]),
        )),
        Positioned(bottom: 100, left: 0, right: 0, child: Center(child: Row(mainAxisSize: MainAxisSize.min, children: [
          _zoomPreset(1), _zoomPreset(2), _zoomPreset(5), _zoomPreset(10),
        ]))),
        Positioned(bottom: 18, left: 0, right: 0, child: Center(child: GestureDetector(onTap: _capturing ? null : _capture, child: Container(
          width: 86, height: 86,
          decoration: BoxDecoration(shape: BoxShape.circle, color: _capturing ? Colors.grey : Colors.red.shade400, border: Border.all(color: Colors.white, width: 4)),
          child: _capturing ? const Center(child: SizedBox(width: 36, height: 36, child: CircularProgressIndicator(strokeWidth: 3, valueColor: AlwaysStoppedAnimation<Color>(Colors.white)))) : const Icon(Icons.camera_alt, color: Colors.white, size: 40),
        )))),
      ]),
    );
  }
}

class PlateGuidePainter extends CustomPainter {
  const PlateGuidePainter({required this.landscapeTilt, required this.withdrawMode});

  final bool landscapeTilt;
  final bool withdrawMode;

  @override
  void paint(Canvas canvas, Size size) {
    // The app remains portrait-locked while the camera follows the physical
    // phone tilt. In that state Flutter can report a portrait logical canvas
    // even though the displayed camera is landscape. Draw the inverse logical
    // shape so the on-screen guide is always a wide plate rectangle.
    final logicalPortrait = size.height > size.width;
    final verticalLogicalGuide = logicalPortrait && landscapeTilt;
    // Scale the landscape guide up uniformly so it is both longer and taller
    // while preserving the same plate aspect ratio.
    final width = verticalLogicalGuide ? size.width *.65 : size.width * .8;
    final height = verticalLogicalGuide ? width * _plateGuideAspectRatio : width / _plateGuideAspectRatio;
    final rect = Rect.fromCenter(center: size.center(Offset.zero), width: width, height: height);
    final dim = Paint()..color = Colors.black.withOpacity(.60);
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, rect.top), dim);
    canvas.drawRect(Rect.fromLTRB(0, rect.bottom, size.width, size.height), dim);
    canvas.drawRect(Rect.fromLTRB(0, rect.top, rect.left, rect.bottom), dim);
    canvas.drawRect(Rect.fromLTRB(rect.right, rect.top, size.width, rect.bottom), dim);
    final corner = Paint()
      ..color = withdrawMode ? Colors.redAccent : Colors.greenAccent
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    // Give the corner cuts a little more visual room when the phone is tilted
    // into landscape, while keeping the portrait guide at its current size.
    final length = landscapeTilt ? 42.0 : 34.0;
    for (final points in [
      [rect.topLeft, rect.topLeft + Offset(length, 0), rect.topLeft + Offset(0, length)],
      [rect.topRight, rect.topRight + Offset(-length, 0), rect.topRight + Offset(0, length)],
      [rect.bottomLeft, rect.bottomLeft + Offset(length, 0), rect.bottomLeft + Offset(0, -length)],
      [rect.bottomRight, rect.bottomRight + Offset(-length, 0), rect.bottomRight + Offset(0, -length)],
    ]) {
      canvas.drawLine(points[0], points[1], corner);
      canvas.drawLine(points[0], points[2], corner);
    }
  }
  @override
  bool shouldRepaint(covariant PlateGuidePainter oldDelegate) => oldDelegate.landscapeTilt != landscapeTilt || oldDelegate.withdrawMode != withdrawMode;
}

class CapturePreviewGuidePainter extends CustomPainter {
  const CapturePreviewGuidePainter({required this.landscapeTilt, required this.withdrawMode});

  final bool landscapeTilt;
  final bool withdrawMode;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTRB(
      size.width * _captureMargin,
      size.height * _captureMargin,
      size.width * (1 - _captureMargin),
      size.height * (1 - _captureMargin),
    );
    final dim = Paint()..color = Colors.black.withOpacity(.60);
    canvas.drawRect(Rect.fromLTRB(0, 0, size.width, rect.top), dim);
    canvas.drawRect(Rect.fromLTRB(0, rect.bottom, size.width, size.height), dim);
    canvas.drawRect(Rect.fromLTRB(0, rect.top, rect.left, rect.bottom), dim);
    canvas.drawRect(Rect.fromLTRB(rect.right, rect.top, size.width, rect.bottom), dim);

    final corner = Paint()
      ..color = withdrawMode ? Colors.redAccent : Colors.greenAccent
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final length = math.min(rect.width, rect.height) * (landscapeTilt ? .22 : .18);
    for (final points in [
      [rect.topLeft, rect.topLeft + Offset(length, 0), rect.topLeft + Offset(0, length)],
      [rect.topRight, rect.topRight + Offset(-length, 0), rect.topRight + Offset(0, length)],
      [rect.bottomLeft, rect.bottomLeft + Offset(length, 0), rect.bottomLeft + Offset(0, -length)],
      [rect.bottomRight, rect.bottomRight + Offset(-length, 0), rect.bottomRight + Offset(0, -length)],
    ]) {
      canvas.drawLine(points[0], points[1], corner);
      canvas.drawLine(points[0], points[2], corner);
    }
  }

  @override
  bool shouldRepaint(covariant CapturePreviewGuidePainter oldDelegate) => oldDelegate.landscapeTilt != landscapeTilt || oldDelegate.withdrawMode != withdrawMode;
}
