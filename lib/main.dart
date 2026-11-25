import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'config/app_theme.dart';
import 'providers/auth_provider.dart';
import 'providers/gate_provider.dart';
import 'screens/manual_capture_screen.dart';
import 'screens/splash_screen.dart';
import 'services/api_service.dart';

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TbsApp());
}

class TbsApp extends StatelessWidget {
  const TbsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AuthProvider>(create: (_) => AuthProvider()),
        ChangeNotifierProvider<GateProvider>(create: (_) => GateProvider()),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'TBS Guard',
        theme: AppTheme.light,
        navigatorKey: appNavigatorKey,
        builder: (context, child) => ManualCaptureWatcher(child: child ?? const SizedBox.shrink()),
        home: const SplashScreen(),
      ),
    );
  }
}

class ManualCaptureWatcher extends StatefulWidget {
  const ManualCaptureWatcher({super.key, required this.child});

  final Widget child;

  @override
  State<ManualCaptureWatcher> createState() => _ManualCaptureWatcherState();
}

class _ManualCaptureWatcherState extends State<ManualCaptureWatcher> {
  Timer? _timer;
  bool _checking = false;
  bool _presenting = false;
  int? _lastRequestId;

  @override
  void initState() {
    super.initState();
    _checkManualCapture();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _checkManualCapture());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _checkManualCapture() async {
    if (_checking || _presenting || !mounted || context.read<AuthProvider>().user == null) return;
    _checking = true;
    try {
      final response = await ApiService.get('/guard/queue/display');
      if (!mounted || !response.isSuccessCode || response.data['data'] is! Map) return;
      final data = Map<String, dynamic>.from(response.data['data'] as Map);
      final pending = data['manual_capture'] is Map ? Map<String, dynamic>.from(data['manual_capture'] as Map) : null;
      final requestId = int.tryParse('${pending?['id'] ?? ''}');
      if (requestId == null) {
        _lastRequestId = null;
        return;
      }
      if (_lastRequestId == requestId) return;
      final navigator = appNavigatorKey.currentState;
      if (navigator == null) return;
      _lastRequestId = requestId;
      _presenting = true;
      await navigator.push(MaterialPageRoute(builder: (_) => ManualCaptureScreen(queueEntryId: requestId, plateNo: '${pending?['plate_no'] ?? ''}')));
      _presenting = false;
    } catch (_) {
      // The next poll will retry when the API is available again.
    } finally {
      _checking = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
