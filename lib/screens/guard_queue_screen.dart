import 'dart:async';

import 'package:flutter/material.dart';

import '../services/api_service.dart';
import 'scan_truck_plate_screen.dart';

class GuardQueueScreen extends StatefulWidget {
  const GuardQueueScreen({super.key});

  @override
  State<GuardQueueScreen> createState() => _GuardQueueScreenState();
}

class _GuardQueueScreenState extends State<GuardQueueScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  Timer? _timer;
  bool _loading = true;
  Map<String, List<Map<String, dynamic>>> _queue = {
    'waiting_in': [],
    'waiting_out': [],
    'serving': []
  };

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 4, vsync: this);
    _loadQueue();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _loadQueue());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadQueue() async {
    try {
      final response = await ApiService.get('/guard/queue/display');
      if (!mounted || !response.isSuccessCode || response.data['data'] is! Map)
        return;
      final data = Map<String, dynamic>.from(response.data['data'] as Map);
      setState(() {
        _queue = {
          'waiting_in': _entries(data['waiting_in']),
          'waiting_out': _entries(data['waiting_out']),
          'serving': _entries(data['serving']),
        };
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
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
      // Keep the scan action usable if the capacity check is unavailable.
    }
    if (!mounted) return;
    Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => const ScanTruckPlateScreen()));
  }

  List<Map<String, dynamic>> _entries(dynamic value) => value is List
      ? value
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList()
      : <Map<String, dynamic>>[];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF3E9AF4),
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text('QUEUE',
            style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700)),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Center(
              child: ElevatedButton.icon(
                onPressed: _openScanScreen,
                icon: const Icon(Icons.qr_code_scanner,
                    color: Colors.white, size: 18),
                label: const Text('SCAN',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4CAF50),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(7)),
                ),
              ),
            ),
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: false,
          tabAlignment: TabAlignment.fill,
          labelPadding: EdgeInsets.zero,
          indicatorSize: TabBarIndicatorSize.tab,
          indicatorPadding:
              const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
          indicator: BoxDecoration(
              color: const Color(0xFF1F2937),
              borderRadius: BorderRadius.circular(18)),
          dividerColor: Colors.transparent,
          labelStyle:
              const TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
          unselectedLabelStyle:
              const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          tabs: const [
            Tab(text: 'ALL'),
            Tab(text: 'WAITING IN'),
            Tab(text: 'WAITING OUT'),
            Tab(text: 'SERVING')
          ],
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF3E9AF4)))
          : TabBarView(controller: _tabs, children: [
              _allQueues(),
              _singleQueue('WAITING', _queue['waiting_in']!, false, 'IN'),
              _singleQueue('WAITING', _queue['waiting_out']!, false, 'OUT'),
              _singleQueue('SERVING', _queue['serving']!, true, null),
            ]),
    );
  }

  Widget _allQueues() => ListView(padding: const EdgeInsets.all(12), children: [
        _queuePanel('WAITING', _queue['waiting_in']!, false, 'IN'),
        const SizedBox(height: 12),
        _queuePanel('WAITING', _queue['waiting_out']!, false, 'OUT'),
        const SizedBox(height: 12),
        _queuePanel('SERVING', _queue['serving']!, true, null),
      ]);

  Widget _singleQueue(String title, List<Map<String, dynamic>> entries,
          bool serving, String? direction) =>
      Padding(
        padding: const EdgeInsets.all(12),
        child: _queuePanel(title, entries, serving, direction),
      );

  Widget _queuePanel(String title, List<Map<String, dynamic>> entries,
      bool serving, String? direction) {
    return Container(
      height: 330,
      decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFD8DDE3)),
          boxShadow: const [
            BoxShadow(
                color: Color(0x14000000), blurRadius: 4, offset: Offset(0, 2))
          ]),
      child: Column(children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
              color:
                  serving ? const Color(0xFF31393C) : const Color(0xFF3E9AF4),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(9))),
          child: Row(children: [
            Icon(serving ? Icons.sensors : Icons.format_list_bulleted,
                color: Colors.white, size: 21),
            const SizedBox(width: 8),
            Expanded(
                child: Text(serving ? title : '$title',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w800))),
            if (!serving) ...[
              const Icon(Icons.local_shipping, color: Colors.white, size: 19),
              const SizedBox(width: 5),
              Text((direction ?? '').toString(),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w800)),
              const SizedBox(width: 10),
            ],
            Text('${entries.length}'.padLeft(2, '0'),
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w900))
          ]),
        ),
        Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text(
                        serving ? 'No trucks being served' : 'Queue is empty',
                        style: const TextStyle(
                            color: Color(0xFF68737B),
                            fontWeight: FontWeight.w600)))
                : ListView.separated(
                    padding: const EdgeInsets.all(10),
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, index) {
                      final entry = entries[index];
                      final plate = (entry['plate_no'] ?? '-').toString();
                      return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 10),
                          decoration: BoxDecoration(
                              color: serving
                                  ? const Color(0xFFECFDF5)
                                  : index == 0
                                      ? const Color(0xFFEFF6FF)
                                      : const Color(0xFFF8F9FA),
                              border: Border.all(
                                  color: serving
                                      ? const Color(0xFFA7F3D0)
                                      : index == 0
                                          ? const Color(0xFFBFDBFE)
                                          : const Color(0xFFDFE3E8)),
                              borderRadius: BorderRadius.circular(9)),
                          child: Row(children: [
                            Container(
                                width: 34,
                                height: 34,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                    color: serving
                                        ? const Color(0xFFD1FAE5)
                                        : index == 0
                                            ? const Color(0xFF3E9AF4)
                                            : const Color(0xFFE5E8EC),
                                    borderRadius: BorderRadius.circular(8)),
                                child: serving
                                    ? const Icon(Icons.local_shipping,
                                        color: Color(0xFF047857), size: 19)
                                    : Text('${index + 1}'.padLeft(2, '0'),
                                        style: TextStyle(
                                            color: index == 0
                                                ? Colors.white
                                                : const Color(0xFF536170),
                                            fontWeight: FontWeight.w900))),
                            const SizedBox(width: 10),
                            Expanded(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  Text(plate,
                                      style: const TextStyle(
                                          color: Color(0xFF202A35),
                                          fontSize: 18,
                                          fontWeight: FontWeight.w800),
                                      overflow: TextOverflow.ellipsis),
                                  Text(
                                      serving
                                          ? 'Now serving'
                                          : index == 0
                                              ? 'Next in line'
                                              : 'Waiting',
                                      style: TextStyle(
                                          color: serving
                                              ? const Color(0xFF047857)
                                              : index == 0
                                                  ? const Color(0xFF1D4ED8)
                                                  : const Color(0xFF68737B),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700))
                                ])),
                            if (!serving)
                              Text(
                                  (entry['direction'] ?? direction ?? '')
                                      .toString(),
                                  style: TextStyle(
                                      color: index == 0
                                          ? const Color(0xFF1D4ED8)
                                          : const Color(0xFF536170),
                                      fontWeight: FontWeight.w900))
                            else
                              Text((entry['direction'] ?? '').toString(),
                                  style: const TextStyle(
                                      color: Color(0xFF047857),
                                      fontWeight: FontWeight.w900))
                          ]));
                    }))
      ]),
    );
  }
}
