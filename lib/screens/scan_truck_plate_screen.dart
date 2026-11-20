import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../services/api_service.dart';

class ScanTruckPlateScreen extends StatefulWidget {
  const ScanTruckPlateScreen({super.key});

  @override
  State<ScanTruckPlateScreen> createState() => _ScanTruckPlateScreenState();
}

class _ScanTruckPlateScreenState extends State<ScanTruckPlateScreen> {
  CameraController? _controller;
  bool _initializing = true;
  bool _capturing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _initializeCamera();
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      final camera = cameras.firstWhere(
        (item) => item.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      final controller = CameraController(camera, ResolutionPreset.high, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _initializing = false;
      });
    } catch (exception) {
      if (!mounted) return;
      setState(() {
        _initializing = false;
        _error = 'Camera could not be opened. Check camera permission.';
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _capturing) return;
    setState(() => _capturing = true);
    try {
      final captured = await controller.takePicture();
      final file = File(captured.path);
      final bytes = await file.readAsBytes();
      final decoded = img.decodeImage(bytes);
      if (decoded == null) throw Exception('Unable to read captured image.');

      // The green guide represents the plate crop: keep the center strip so
      // OCR receives a plate-shaped image instead of the whole truck frame.
      final cropWidth = (decoded.width * 0.90).round();
      final cropHeight = (decoded.height * 0.35).round();
      final cropped = img.copyCrop(
        decoded,
        x: ((decoded.width - cropWidth) / 2).round(),
        y: ((decoded.height - cropHeight) / 2).round(),
        width: cropWidth,
        height: cropHeight,
      );
      final cropPath = '${file.path}_plate.jpg';
      final cropFile = File(cropPath);
      await cropFile.writeAsBytes(img.encodeJpg(cropped, quality: 92));
      final sharpness = _laplacianVariance(cropped);
      if (sharpness < 22) {
        await _showMessage('Image is blurred', 'Hold the phone steady and make sure the plate is inside the guide before capturing again.');
        return;
      }

      final response = await ApiService.postMultipart('/guard/scan-truck-plate', file: cropFile);
      if (!mounted) return;
      if (!response.isSuccessCode || response.data['success'] != true) {
        await _showMessage('Scan failed', ApiService.extractMessage(response.data));
        return;
      }

      final plate = response.data['plate_no']?.toString() ?? '';
      final moved = response.data['queue_updated'] == true;
      await _showMessage(moved ? 'Truck found in queue' : 'This Truck is not in Queue', moved ? '$plate was moved to Serving.' : 'Detected plate: $plate');
    } catch (exception) {
      if (mounted) await _showMessage('Scan failed', 'Please capture a clearer plate image and try again.');
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  double _laplacianVariance(img.Image source) {
    final gray = img.grayscale(source);
    final width = gray.width;
    final height = gray.height;
    if (width < 3 || height < 3) return 0;
    final samples = <double>[];
    for (var y = 1; y < height - 1; y += 4) {
      for (var x = 1; x < width - 1; x += 4) {
        final center = gray.getPixel(x, y).luminance;
        final double laplacian = (gray.getPixel(x - 1, y).luminance + gray.getPixel(x + 1, y).luminance + gray.getPixel(x, y - 1).luminance + gray.getPixel(x, y + 1).luminance - (4 * center)).toDouble();
        samples.add(laplacian);
      }
    }
    final mean = samples.reduce((a, b) => a + b) / samples.length;
    return samples.map((value) => math.pow(value - mean, 2).toDouble()).reduce((a, b) => a + b) / samples.length;
  }

  Future<void> _showMessage(String title, String message) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(title: Text(title), content: Text(message), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFF3E9AF4),
        title: const Text('SCAN TRUCK PLATE', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: _initializing
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : _error != null
              ? Center(child: Text(_error!, style: const TextStyle(color: Colors.white)))
              : Stack(
                  fit: StackFit.expand,
                  children: [
                    if (controller != null) CameraPreview(controller),
                    Center(
                      child: AspectRatio(
                        aspectRatio: 2.7,
                        child: Container(decoration: BoxDecoration(border: Border.all(color: Colors.greenAccent, width: 3), borderRadius: BorderRadius.circular(12), color: Colors.transparent)),
                      ),
                    ),
                    const Positioned(top: 24, left: 20, right: 20, child: Text('Fit the entire plate inside the guide. Keep it steady and clear.', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600, shadows: [Shadow(blurRadius: 4, color: Colors.black)]))),
                    Positioned(bottom: 28, left: 24, right: 24, child: SizedBox(height: 54, child: ElevatedButton.icon(onPressed: _capturing ? null : _capture, icon: _capturing ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.camera_alt), label: Text(_capturing ? 'PROCESSING...' : 'CAPTURE'), style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF3E9AF4), foregroundColor: Colors.white, textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700))))),
                  ],
                ),
    );
  }
}
