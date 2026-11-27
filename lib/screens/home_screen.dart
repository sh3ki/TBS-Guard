import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:permission_handler/permission_handler.dart';

import '../providers/auth_provider.dart';
import '../services/app_update_service.dart';
import '../services/api_service.dart';
import 'scan_truck_plate_screen.dart';
import 'guard_queue_screen.dart';
import 'login_screen.dart';

/// Guard home shell. It intentionally has no menu actions yet.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  late final Future<String> _installedVersionFuture;
  bool _needsPermissions = false;
  bool _hasCallingEntry = false;
  Map<Permission, PermissionStatus> _statuses = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _installedVersionFuture = AppUpdateService.getInstalledVersion();
    _checkPermissions();
    _loadScanAvailability();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermissions();
      _loadScanAvailability();
    }
  }

  Future<void> _checkPermissions() async {
    final camera = await Permission.camera.status;
    final microphone = await Permission.microphone.status;
    final photos = await Permission.photos.status;
    final videos = await Permission.videos.status;
    final storage = await Permission.storage.status;
    final fileAccess =
        photos.isGranted || videos.isGranted || storage.isGranted;
    if (!mounted) return;
    setState(() {
      _statuses = {
        Permission.camera: camera,
        Permission.microphone: microphone,
        Permission.photos: photos,
        Permission.videos: videos,
        Permission.storage: storage,
      };
      _needsPermissions =
          !(camera.isGranted && microphone.isGranted && fileAccess);
    });
  }

  Future<void> _loadScanAvailability() async {
    try {
      final user = context.read<AuthProvider>().user;
      final response = await ApiService.get('/guard/queue/display', token: user?.token);
      if (!mounted || !response.isSuccessCode || response.data['success'] != true) return;
      final data = Map<String, dynamic>.from(response.data['data'] as Map);
      final waitingIn = (data['waiting_in'] as List? ?? const []).whereType<Map>();
      final waitingOut = (data['waiting_out'] as List? ?? const []).whereType<Map>();
      final hasCalling = [...waitingIn, ...waitingOut].any((entry) => entry['status']?.toString() == 'calling');
      setState(() => _hasCallingEntry = hasCalling);
    } catch (_) {
      if (mounted) setState(() => _hasCallingEntry = false);
    }
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.camera,
      Permission.microphone,
      Permission.photos,
      Permission.videos,
      Permission.storage
    ].request();
    await _checkPermissions();
    if (mounted && _needsPermissions) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Please enable required permissions in Settings')));
    }
  }

  Future<void> _logout() async {
    await context.read<AuthProvider>().logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginScreen()),
      (route) => false,
    );
  }

  Future<void> _openScanScreen() async {
    try {
      final response = await ApiService.get('/guard/queue-capacity');
      if (!mounted) return;
      if (response.isSuccessCode && response.data['at_capacity'] == true) {
        await showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            backgroundColor: const Color(0xFFDC2626),
            icon: const Icon(Icons.block, color: Colors.white, size: 52),
            title: const Text('Serving Capacity Full',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.w700)),
            content: const Text(
                'Serving capacity is full. Please wait until a truck is completed.',
                style: TextStyle(color: Colors.white)),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('CLOSE',
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold))),
            ],
          ),
        );
        return;
      }
    } catch (_) {
      // If the capacity service is temporarily unavailable, keep the scan action usable.
    }
    if (!mounted) return;
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ScanTruckPlateScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthProvider>();
    final fullName = auth.user?.fullName.trim();
    final username = auth.user?.username.trim() ?? '';

    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF3E9AF4),
        elevation: 0,
        title: const Text(
          'TBS Container Yard',
          style: TextStyle(
              fontSize: 18, fontWeight: FontWeight.w600, color: Colors.white),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: FutureBuilder<String>(
                future: _installedVersionFuture,
                builder: (context, snapshot) => Text(
                  snapshot.hasData && snapshot.data!.isNotEmpty
                      ? 'v${snapshot.data}'
                      : 'Version unavailable',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Colors.white70),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Container(
        color: Colors.grey[50],
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            if (_needsPermissions)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.shade100,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.shade700),
                ),
                child: Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Permissions required',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black87)),
                          SizedBox(height: 6),
                          Text(
                              'The app needs Camera, Microphone and File access to work properly. Please grant permissions.',
                              style: TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      children: [
                        ElevatedButton(
                            onPressed: _requestPermissions,
                            style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.orange),
                            child: const Text('Grant')),
                        const SizedBox(height: 6),
                        TextButton(
                            onPressed: openAppSettings,
                            child: const Text('Open Settings')),
                      ],
                    ),
                  ],
                ),
              ),
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 4,
                      offset: const Offset(0, 2))
                ],
              ),
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                        color: const Color(0xFF3E9AF4),
                        borderRadius: BorderRadius.circular(8)),
                    child:
                        const Icon(Icons.person, color: Colors.white, size: 24),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            fullName != null && fullName.isNotEmpty
                                ? fullName
                                : username,
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF31393C))),
                        const SizedBox(height: 2),
                        Text(username,
                            style: TextStyle(
                                fontSize: 13, color: Colors.grey[600])),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            Expanded(
              child: Column(
                children: [
                  _buildMenuButton(
                    context: context,
                    icon: Icons.format_list_bulleted,
                    label: 'QUEUE',
                    subtitle: 'View the truck queue',
                    color: const Color(0xFF3E9AF4),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const GuardQueueScreen()),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _buildMenuButton(
                    context: context,
                    icon: Icons.qr_code_scanner,
                    label: 'SCAN TRUCK PLATE',
                    subtitle: 'Scan a truck plate number',
                    color: _hasCallingEntry ? const Color(0xFF4CAF50) : const Color(0xFF9CA3AF),
                    onPressed: _hasCallingEntry ? _openScanScreen : null,
                  ),
                ],
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _logout,
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey[300],
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8))),
                child: const Text('LOGOUT',
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF31393C))),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuButton({
    required BuildContext context,
    required IconData icon,
    required String label,
    required String subtitle,
    required Color color,
    required VoidCallback? onPressed,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.15),
                  blurRadius: 4,
                  offset: const Offset(0, 2))
            ],
          ),
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.25),
                    borderRadius: BorderRadius.circular(8)),
                child: Center(child: Icon(icon, color: Colors.white, size: 28)),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.white)),
                    const SizedBox(height: 4),
                    Text(subtitle,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                            color: Colors.white)),
                  ],
                ),
              ),
              const Icon(Icons.arrow_forward_ios,
                  color: Colors.white, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

class GuardPlaceholderScreen extends StatelessWidget {
  final String title;

  const GuardPlaceholderScreen({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF3E9AF4),
        title: Text(title,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w600)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: const SizedBox.expand(),
    );
  }
}
