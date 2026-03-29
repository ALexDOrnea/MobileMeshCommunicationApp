import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const String kServiceUuid = "12345678-1234-1234-1234-1234567890ab";
const String kTxCharacteristicUuid =
    "12345678-1234-1234-1234-1234567890ac"; // write
const String kRxCharacteristicUuid =
    "12345678-1234-1234-1234-1234567890ad"; // notify

void main() {
  runApp(const MeshChatApp());
}

class MeshChatApp extends StatelessWidget {
  const MeshChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE Chat Draft',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.blue),
      home: const ChatListPage(),
    );
  }
}

class ChatThread {
  final String id;
  final String title;
  final String? deviceId;
  bool persistent;
  List<ChatMessage> messages;

  ChatThread({
    required this.id,
    required this.title,
    required this.deviceId,
    required this.persistent,
    required this.messages,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'deviceId': deviceId,
    'persistent': persistent,
    'messages': messages.map((e) => e.toJson()).toList(),
  };

  factory ChatThread.fromJson(Map<String, dynamic> json) => ChatThread(
    id: json['id'],
    title: json['title'],
    deviceId: json['deviceId'],
    persistent: json['persistent'] ?? false,
    messages: (json['messages'] as List<dynamic>? ?? [])
        .map((e) => ChatMessage.fromJson(Map<String, dynamic>.from(e)))
        .toList(),
  );
}

class ChatMessage {
  final String id;
  final String text;
  final bool isMine;
  final DateTime timestamp;

  ChatMessage({
    required this.id,
    required this.text,
    required this.isMine,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'isMine': isMine,
    'timestamp': timestamp.toIso8601String(),
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'],
    text: json['text'],
    isMine: json['isMine'],
    timestamp: DateTime.parse(json['timestamp']),
  );
}

class LocalStore {
  static const _threadsKey = 'chat_threads';

  static Future<List<ChatThread>> loadThreads() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_threadsKey);
    if (raw == null || raw.isEmpty) return [];
    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((e) => ChatThread.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  static Future<void> saveThreads(List<ChatThread> threads) async {
    final prefs = await SharedPreferences.getInstance();
    final data = jsonEncode(threads.map((e) => e.toJson()).toList());
    await prefs.setString(_threadsKey, data);
  }
}

class BleChatService {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _txCharacteristic;
  BluetoothCharacteristic? _rxCharacteristic;
  StreamSubscription<List<int>>? _notifySub;

  final _incomingController = StreamController<String>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();

  Stream<String> get incomingMessages => _incomingController.stream;
  Stream<bool> get connectionState => _connectionStateController.stream;

  BluetoothDevice? get device => _device;

  Future<void> connectToDevice(BluetoothDevice device) async {
    _device = device;

    await device.connect(timeout: const Duration(seconds: 12));

    final services = await device.discoverServices();
    BluetoothCharacteristic? tx;
    BluetoothCharacteristic? rx;

    for (final service in services) {
      if (service.uuid.str128.toLowerCase() == kServiceUuid.toLowerCase()) {
        for (final c in service.characteristics) {
          final uuid = c.uuid.str128.toLowerCase();
          if (uuid == kTxCharacteristicUuid.toLowerCase()) {
            tx = c;
          }
          if (uuid == kRxCharacteristicUuid.toLowerCase()) {
            rx = c;
          }
        }
      }
    }

    if (tx == null || rx == null) {
      throw Exception('Nu am găsit caracteristicile BLE necesare.');
    }

    _txCharacteristic = tx;
    _rxCharacteristic = rx;

    await _rxCharacteristic!.setNotifyValue(true);
    _notifySub?.cancel();
    _notifySub = _rxCharacteristic!.lastValueStream.listen((value) {
      if (value.isEmpty) return;
      final text = utf8.decode(value, allowMalformed: true);
      _incomingController.add(text);
    });

    _connectionStateController.add(true);
  }

  Future<void> sendMessage(String message) async {
    final tx = _txCharacteristic;
    if (tx == null) {
      throw Exception('Nu există conexiune BLE activă.');
    }

    final bytes = utf8.encode(message);
    await tx.write(bytes, withoutResponse: false);
  }

  Future<void> disconnect() async {
    await _notifySub?.cancel();
    _notifySub = null;

    try {
      await _device?.disconnect();
    } catch (_) {}

    _device = null;
    _txCharacteristic = null;
    _rxCharacteristic = null;
    _connectionStateController.add(false);
  }

  void dispose() {
    _notifySub?.cancel();
    _incomingController.close();
    _connectionStateController.close();
  }
}

class ChatListPage extends StatefulWidget {
  const ChatListPage({super.key});

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage> {
  final _uuid = const Uuid();
  List<ChatThread> _threads = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final threads = await LocalStore.loadThreads();
    setState(() {
      _threads = threads;
      _loading = false;
    });
  }

  Future<void> _persist() async {
    final threadsToSave = _threads
        .where((t) => t.persistent)
        .map((t) => t)
        .toList();
    await LocalStore.saveThreads(threadsToSave);
  }

  Future<void> _createManualChat() async {
    final thread = ChatThread(
      id: _uuid.v4(),
      title: 'Chat local',
      deviceId: null,
      persistent: false,
      messages: [],
    );
    setState(() => _threads.insert(0, thread));
    await _persist();
  }

  Future<void> _openScanner() async {
    final result = await Navigator.push<ChatThread>(
      context,
      MaterialPageRoute(builder: (_) => const DeviceScannerPage()),
    );

    if (result != null) {
      setState(() {
        _threads.removeWhere((t) => t.id == result.id);
        _threads.insert(0, result);
      });
      await _persist();
    }
  }

  Future<void> _deleteThread(ChatThread thread) async {
    setState(() {
      _threads.removeWhere((t) => t.id == thread.id);
    });
    await _persist();
  }

  Future<void> _togglePersistence(ChatThread thread, bool value) async {
    setState(() {
      thread.persistent = value;
    });
    await _persist();
  }

  Future<void> _openThread(ChatThread thread) async {
    final updated = await Navigator.push<ChatThread>(
      context,
      MaterialPageRoute(builder: (_) => ChatRoomPage(initialThread: thread)),
    );

    if (updated != null) {
      final index = _threads.indexWhere((t) => t.id == updated.id);
      if (index != -1) {
        setState(() {
          _threads[index] = updated;
        });
        await _persist();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat-uri BLE'),
        actions: [
          IconButton(
            onPressed: _openScanner,
            icon: const Icon(Icons.bluetooth_searching),
            tooltip: 'Scanează device-uri',
          ),
          IconButton(
            onPressed: _createManualChat,
            icon: const Icon(Icons.add_comment_outlined),
            tooltip: 'Chat local',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _threads.isEmpty
          ? const Center(
              child: Text('Nu există chat-uri. Scanează un device BLE.'),
            )
          : ListView.builder(
              itemCount: _threads.length,
              itemBuilder: (_, index) {
                final thread = _threads[index];
                final last = thread.messages.isNotEmpty
                    ? thread.messages.last.text
                    : 'Fără mesaje';
                return Dismissible(
                  key: ValueKey(thread.id),
                  background: Container(color: Colors.red),
                  onDismissed: (_) => _deleteThread(thread),
                  child: ListTile(
                    title: Text(thread.title),
                    subtitle: Text(
                      last,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    leading: const Icon(Icons.chat_bubble_outline),
                    trailing: Switch(
                      value: thread.persistent,
                      onChanged: (v) => _togglePersistence(thread, v),
                    ),
                    onTap: () => _openThread(thread),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openScanner,
        icon: const Icon(Icons.search),
        label: const Text('Scan BLE'),
      ),
    );
  }
}

class DeviceScannerPage extends StatefulWidget {
  const DeviceScannerPage({super.key});

  @override
  State<DeviceScannerPage> createState() => _DeviceScannerPageState();
}

class _DeviceScannerPageState extends State<DeviceScannerPage> {
  final _uuid = const Uuid();
  StreamSubscription<List<ScanResult>>? _scanSub;
  final Map<String, ScanResult> _results = {};
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  Future<void> _startScan() async {
    setState(() => _isScanning = true);

    _scanSub?.cancel();
    _results.clear();

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        _results[r.device.remoteId.str] = r;
      }
      if (mounted) setState(() {});
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
    await Future.delayed(const Duration(seconds: 8));
    if (mounted) {
      setState(() => _isScanning = false);
    }
  }

  Future<void> _stopScan() async {
    await FlutterBluePlus.stopScan();
    await _scanSub?.cancel();
    _scanSub = null;
    if (mounted) {
      setState(() => _isScanning = false);
    }
  }

  @override
  void dispose() {
    _stopScan();
    super.dispose();
  }

  String _displayName(ScanResult r) {
    final p = r.device.platformName.trim();
    if (p.isNotEmpty) return p;
    final a = r.advertisementData.advName.trim();
    if (a.isNotEmpty) return a;
    return 'Unknown device';
  }

  @override
  Widget build(BuildContext context) {
    final list = _results.values.toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('BLE devices'),
        actions: [
          IconButton(
            onPressed: _isScanning ? null : _startScan,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isScanning) const LinearProgressIndicator(),
          Expanded(
            child: list.isEmpty
                ? const Center(child: Text('Niciun device găsit încă'))
                : ListView.separated(
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, index) {
                      final result = list[index];
                      final name = _displayName(result);
                      return ListTile(
                        leading: const Icon(Icons.bluetooth),
                        title: Text(name),
                        subtitle: Text(result.device.remoteId.str),
                        trailing: Text('RSSI ${result.rssi}'),
                        onTap: () {
                          final thread = ChatThread(
                            id: _uuid.v4(),
                            title: name,
                            deviceId: result.device.remoteId.str,
                            persistent: false,
                            messages: [],
                          );
                          Navigator.pop(context, thread);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class ChatRoomPage extends StatefulWidget {
  final ChatThread initialThread;

  const ChatRoomPage({super.key, required this.initialThread});

  @override
  State<ChatRoomPage> createState() => _ChatRoomPageState();
}

class _ChatRoomPageState extends State<ChatRoomPage> {
  late ChatThread _thread;
  final _controller = TextEditingController();
  final _uuid = const Uuid();
  final _ble = BleChatService();

  bool _connecting = false;
  bool _connected = false;
  StreamSubscription<String>? _incomingSub;
  StreamSubscription<bool>? _stateSub;

  @override
  void initState() {
    super.initState();
    _thread = ChatThread(
      id: widget.initialThread.id,
      title: widget.initialThread.title,
      deviceId: widget.initialThread.deviceId,
      persistent: widget.initialThread.persistent,
      messages: [...widget.initialThread.messages],
    );

    _incomingSub = _ble.incomingMessages.listen((message) {
      setState(() {
        _thread.messages.add(
          ChatMessage(
            id: _uuid.v4(),
            text: message,
            isMine: false,
            timestamp: DateTime.now(),
          ),
        );
      });
    });

    _stateSub = _ble.connectionState.listen((state) {
      if (mounted) {
        setState(() {
          _connected = state;
        });
      }
    });
  }

  Future<void> _connect() async {
    if (_thread.deviceId == null) return;

    setState(() => _connecting = true);
    try {
      final bonded = FlutterBluePlus.connectedDevices;
      BluetoothDevice? device;

      for (final d in bonded) {
        if (d.remoteId.str == _thread.deviceId) {
          device = d;
          break;
        }
      }

      device ??= BluetoothDevice.fromId(_thread.deviceId!);

      await _ble.connectToDevice(device);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Conectat')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Eroare conectare: $e')));
      }
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _disconnect() async {
    await _ble.disconnect();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _thread.messages.add(
        ChatMessage(
          id: _uuid.v4(),
          text: text,
          isMine: true,
          timestamp: DateTime.now(),
        ),
      );
    });

    _controller.clear();

    try {
      await _ble.sendMessage(text);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Trimiterea a eșuat: $e')));
      }
    }
  }

  Future<bool> _onWillPop() async {
    Navigator.pop(context, _thread);
    return false;
  }

  @override
  void dispose() {
    _incomingSub?.cancel();
    _stateSub?.cancel();
    _ble.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (_) async => _onWillPop(),
      child: Scaffold(
        appBar: AppBar(
          title: Text(_thread.title),
          actions: [
            Row(
              children: [
                const Text('Salvează'),
                Switch(
                  value: _thread.persistent,
                  onChanged: (v) => setState(() => _thread.persistent = v),
                ),
              ],
            ),
            if (_thread.deviceId != null)
              IconButton(
                onPressed: _connected
                    ? _disconnect
                    : (_connecting ? null : _connect),
                icon: Icon(_connected ? Icons.link_off : Icons.link),
              ),
          ],
        ),
        body: Column(
          children: [
            Material(
              color: Colors.black12,
              child: ListTile(
                leading: Icon(
                  _connected
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_disabled,
                ),
                title: Text(_thread.deviceId ?? 'Chat fără device BLE'),
                subtitle: Text(
                  _connected
                      ? 'Conectat'
                      : (_connecting ? 'Se conectează...' : 'Neconectat'),
                ),
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(12),
                itemCount: _thread.messages.length,
                itemBuilder: (_, index) {
                  final m = _thread.messages[index];
                  return Align(
                    alignment: m.isMine
                        ? Alignment.centerRight
                        : Alignment.centerLeft,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      constraints: const BoxConstraints(maxWidth: 280),
                      decoration: BoxDecoration(
                        color: m.isMine
                            ? Colors.blue.shade100
                            : Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(m.text),
                          const SizedBox(height: 4),
                          Text(
                            '${m.timestamp.hour.toString().padLeft(2, '0')}:${m.timestamp.minute.toString().padLeft(2, '0')}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        decoration: const InputDecoration(
                          hintText: 'Mesaj',
                          border: OutlineInputBorder(),
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(onPressed: _send, icon: const Icon(Icons.send)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
