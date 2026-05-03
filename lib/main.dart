import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_ble_peripheral/flutter_ble_peripheral.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

// --- CONSTANTE UUID ---
const String kServiceUuid = "12345678-1234-1234-1234-1234567890ab";
const String kTxCharacteristicUuid = "12345678-1234-1234-1234-1234567890ac";
const String kRxCharacteristicUuid = "12345678-1234-1234-1234-1234567890ad";

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(
    ChangeNotifierProvider(
      create: (_) => SettingsProvider(prefs),
      child: const MeshChatApp(),
    ),
  );
}

// --- MODELE DE DATE ---
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

class ChatThread {
  final String id;
  final String title;
  final String? deviceId;
  List<ChatMessage> messages;
  ChatThread({
    required this.id,
    required this.title,
    this.deviceId,
    required this.messages,
  });
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'deviceId': deviceId,
    'messages': messages.map((e) => e.toJson()).toList(),
  };
  factory ChatThread.fromJson(Map<String, dynamic> json) => ChatThread(
    id: json['id'],
    title: json['title'],
    deviceId: json['deviceId'],
    messages: (json['messages'] as List)
        .map((e) => ChatMessage.fromJson(e))
        .toList(),
  );
}

// --- PROVIDER SETĂRI ---
class SettingsProvider extends ChangeNotifier {
  final SharedPreferences _prefs;
  bool _isDarkMode = true;
  bool _saveHistory = true;
  Color _accentColor = const Color(0xFF0052D4);
  List<ChatThread> _threads = [];

  SettingsProvider(this._prefs) {
    _isDarkMode = _prefs.getBool('dark_mode') ?? true;
    _saveHistory = _prefs.getBool('save_history') ?? true;
    _accentColor = Color(_prefs.getInt('accent_color') ?? 0xFF0052D4);
    _loadThreads();
  }

  bool get isDarkMode => _isDarkMode;
  bool get saveHistory => _saveHistory;
  Color get accentColor => _accentColor;
  List<ChatThread> get threads => _threads;

  void toggleTheme(bool val) {
    _isDarkMode = val;
    _prefs.setBool('dark_mode', val);
    notifyListeners();
  }

  void toggleSaveHistory(bool val) {
    _saveHistory = val;
    _prefs.setBool('save_history', val);
    notifyListeners();
  }

  void updateAccent(Color c) {
    _accentColor = c;
    _prefs.setInt('accent_color', c.value);
    notifyListeners();
  }

  void _loadThreads() {
    final raw = _prefs.getString('chat_threads');
    if (raw != null) {
      final List decoded = jsonDecode(raw);
      _threads = decoded.map((e) => ChatThread.fromJson(e)).toList();
      notifyListeners();
    }
  }

  void saveThread(ChatThread thread) {
    if (!_saveHistory) return;
    _threads.removeWhere((t) => t.id == thread.id);
    _threads.insert(0, thread);
    _prefs.setString(
      'chat_threads',
      jsonEncode(_threads.map((e) => e.toJson()).toList()),
    );
    notifyListeners();
  }

  void clearChats() {
    _threads.clear();
    _prefs.remove('chat_threads');
    notifyListeners();
  }
}

// --- APP ENTRY ---
class MeshChatApp extends StatelessWidget {
  const MeshChatApp({super.key});
  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: settings.isDarkMode ? ThemeMode.dark : ThemeMode.light,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: settings.accentColor,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: settings.accentColor,
        scaffoldBackgroundColor: const Color(0xFF0F1115),
      ),
      home: const MainShell(),
    );
  }
}

// --- NAVIGARE ---
class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _idx = 1;
  final PageController _pageController = PageController(initialPage: 1);
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _pageController,
        onPageChanged: (i) => setState(() => _idx = i),
        children: [
          const DeviceScannerPage(),
          ChatListPage(
            onNewChatPressed: () => _pageController.animateToPage(
              0,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
            ),
          ),
          const SettingsPage(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _idx,
        onTap: (i) => _pageController.animateToPage(
          i,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        ),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.fullscreen_exit),
            label: 'Scan',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.chat_bubble_outline),
            label: 'Chats',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

// --- CHAT LIST ---
class ChatListPage extends StatelessWidget {
  final VoidCallback onNewChatPressed;
  const ChatListPage({super.key, required this.onNewChatPressed});
  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('MeshChat'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text(
                '• ${settings.threads.length} active',
                style: const TextStyle(color: Colors.green, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                TextField(
                  decoration: InputDecoration(
                    hintText: 'Search chats...',
                    prefixIcon: const Icon(Icons.search),
                    filled: true,
                    fillColor: Theme.of(context).cardColor,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: ListView.builder(
                    itemCount: settings.threads.length,
                    itemBuilder: (context, i) {
                      final t = settings.threads[i];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: settings.accentColor,
                          child: Text(
                            t.title.isNotEmpty ? t.title[0] : "?",
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                        title: Text(t.title),
                        subtitle: Text(
                          t.messages.isNotEmpty
                              ? t.messages.last.text
                              : "No messages",
                          maxLines: 1,
                        ),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ModernChatRoom(thread: t),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: ElevatedButton(
              onPressed: onNewChatPressed,
              style: ElevatedButton.styleFrom(
                backgroundColor: settings.accentColor,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 50),
              ),
              child: const Text('+ New Chat'),
            ),
          ),
        ],
      ),
    );
  }
}

// --- SCAN PAGE ---
class DeviceScannerPage extends StatefulWidget {
  const DeviceScannerPage({super.key});
  @override
  State<DeviceScannerPage> createState() => _DeviceScannerPageState();
}

class _DeviceScannerPageState extends State<DeviceScannerPage> {
  List<ScanResult> _allResults = [];
  List<ScanResult> _filteredResults = [];
  bool _isScan = false;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_filterDevices);
    _startAdvertising();
  }

  // FUNCȚIA MODIFICATĂ PENTRU VIZIBILITATE MAXIMĂ
  void _startAdvertising() async {
    final AdvertiseData advertiseData = AdvertiseData(
      serviceUuid: kServiceUuid,
      localName: "MeshChat-Node",
    );

    final AdvertiseSettings advertiseSettings = AdvertiseSettings(
      advertiseMode: AdvertiseMode.advertiseModeLowLatency,
      txPowerLevel: AdvertiseTxPower.advertiseTxPowerHigh,
      connectable: true, // ACEASTA PERMITE CONECTAREA
    );

    try {
      if (await FlutterBlePeripheral().isSupported) {
        await FlutterBlePeripheral().start(
          advertiseData: advertiseData,
          advertiseSettings: advertiseSettings,
        );
        debugPrint("Advertising pornit!");
      }
    } catch (e) {
      debugPrint("Eroare Advertising: $e");
    }
  }

  void _filterDevices() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredResults = _allResults.where((r) {
        final name =
            (r.device.platformName.isEmpty
                    ? r.advertisementData.advName
                    : r.device.platformName)
                .toLowerCase();
        return name.contains(query) ||
            r.device.remoteId.str.toLowerCase().contains(query);
      }).toList();
    });
  }

  void _start() async {
    if (await FlutterBluePlus.isSupported == false) return;
    if (await FlutterBluePlus.adapterState.first != BluetoothAdapterState.on) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text("Porniți Bluetooth!")));
      return;
    }
    setState(() {
      _allResults.clear();
      _filteredResults.clear();
      _isScan = true;
    });
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    FlutterBluePlus.scanResults.listen((results) {
      if (mounted) {
        setState(() {
          _allResults = results
              .where(
                (r) =>
                    r.device.platformName.isNotEmpty ||
                    r.advertisementData.advName.isNotEmpty,
              )
              .toList();
          _filterDevices();
        });
      }
    });
    await Future.delayed(const Duration(seconds: 10));
    if (mounted) setState(() => _isScan = false);
  }

  @override
  void dispose() {
    _searchController.dispose();
    FlutterBlePeripheral().stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Devices')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _isScan ? null : _start,
                icon: const Icon(Icons.sync),
                label: Text(_isScan ? 'Scanning...' : 'Scan for Devices'),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search...',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Theme.of(context).cardColor,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: ListView.builder(
                itemCount: _filteredResults.length,
                itemBuilder: (context, i) {
                  final r = _filteredResults[i];
                  final name = r.device.platformName.isNotEmpty
                      ? r.device.platformName
                      : r.advertisementData.advName;
                  return Card(
                    child: ListTile(
                      leading: const Icon(Icons.bluetooth, color: Colors.green),
                      title: Text(name),
                      subtitle: Text(r.device.remoteId.str),
                      trailing: ElevatedButton(
                        onPressed: () {
                          final newThread = ChatThread(
                            id: const Uuid().v4(),
                            title: name,
                            deviceId: r.device.remoteId.str,
                            messages: [],
                          );
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => ModernChatRoom(
                                thread: newThread,
                                device: r.device,
                              ),
                            ),
                          );
                        },
                        child: const Text("Connect"),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- CHAT ROOM ---
class ModernChatRoom extends StatefulWidget {
  final ChatThread thread;
  final BluetoothDevice? device;
  const ModernChatRoom({super.key, required this.thread, this.device});
  @override
  State<ModernChatRoom> createState() => _ModernChatRoomState();
}

class _ModernChatRoomState extends State<ModernChatRoom> {
  final _msgController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  BluetoothCharacteristic? _tx;
  StreamSubscription? _rxSub;
  bool _isConnected = false;

  @override
  void initState() {
    super.initState();
    if (widget.device != null) _connect();
  }

  void _connect() async {
    try {
      await widget.device!.connect();
      setState(() => _isConnected = true);
      final services = await widget.device!.discoverServices();
      for (var s in services) {
        if (s.uuid.str128.toLowerCase() == kServiceUuid) {
          for (var c in s.characteristics) {
            if (c.uuid.str128.toLowerCase() == kTxCharacteristicUuid) _tx = c;
            if (c.uuid.str128.toLowerCase() == kRxCharacteristicUuid) {
              await c.setNotifyValue(true);
              _rxSub = c.lastValueStream.listen((val) {
                if (val.isEmpty) return;
                setState(() {
                  widget.thread.messages.add(
                    ChatMessage(
                      id: const Uuid().v4(),
                      text: utf8.decode(val),
                      isMine: false,
                      timestamp: DateTime.now(),
                    ),
                  );
                });
                _scrollToBottom();
                Provider.of<SettingsProvider>(
                  context,
                  listen: false,
                ).saveThread(widget.thread);
              });
            }
          }
        }
      }
    } catch (e) {
      debugPrint("Eroare conexiune: $e");
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients)
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
    });
  }

  void _send() async {
    if (_msgController.text.trim().isEmpty) return;
    final txt = _msgController.text.trim();
    setState(() {
      widget.thread.messages.add(
        ChatMessage(
          id: const Uuid().v4(),
          text: txt,
          isMine: true,
          timestamp: DateTime.now(),
        ),
      );
    });
    _scrollToBottom();
    if (_tx != null) {
      try {
        await _tx!.write(utf8.encode(txt));
      } catch (e) {
        debugPrint("Eroare send: $e");
      }
    }
    _msgController.clear();
    Provider.of<SettingsProvider>(
      context,
      listen: false,
    ).saveThread(widget.thread);
  }

  @override
  void dispose() {
    _rxSub?.cancel();
    _msgController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.thread.title),
            Text(
              _isConnected ? "Conectat" : "Deconectat",
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              itemCount: widget.thread.messages.length,
              itemBuilder: (context, i) {
                final m = widget.thread.messages[i];
                return Align(
                  alignment: m.isMine
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: m.isMine
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      m.text,
                      style: TextStyle(color: m.isMine ? Colors.white : null),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _msgController,
                    decoration: const InputDecoration(hintText: "Mesaj..."),
                  ),
                ),
                IconButton(onPressed: _send, icon: const Icon(Icons.send)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// --- SETTINGS ---
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final s = Provider.of<SettingsProvider>(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: s.accentColor,
              child: const Text('ME'),
            ),
            title: const Text('My Device'),
            subtitle: Text(Platform.isAndroid ? "Android Node" : "iOS Node"),
          ),
          SwitchListTile(
            title: const Text("Save History"),
            value: s.saveHistory,
            onChanged: (v) => s.toggleSaveHistory(v),
          ),
          ListTile(
            leading: const Icon(Icons.delete, color: Colors.red),
            title: const Text("Clear Chats"),
            onTap: () => s.clearChats(),
          ),
          SwitchListTile(
            title: const Text("Dark Mode"),
            value: s.isDarkMode,
            onChanged: (v) => s.toggleTheme(v),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children:
                [
                      Colors.blue,
                      Colors.purple,
                      Colors.green,
                      Colors.orange,
                      Colors.pink,
                    ]
                    .map(
                      (c) => GestureDetector(
                        onTap: () => s.updateAccent(c),
                        child: CircleAvatar(
                          backgroundColor: c,
                          radius: 18,
                          child: s.accentColor.value == c.value
                              ? const Icon(Icons.check, color: Colors.white)
                              : null,
                        ),
                      ),
                    )
                    .toList(),
          ),
        ],
      ),
    );
  }
}
