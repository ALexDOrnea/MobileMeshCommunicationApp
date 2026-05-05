import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const String kNearbyServiceId = "com.meshup.chat";

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

// --- NEARBY MESSAGE BUS ---
enum NearbyIncomingType { text, file }

class NearbyIncomingMessage {
  final String endpointId;
  final String text;
  final NearbyIncomingType type;
  final String? filePath;
  final String? fileName;

  NearbyIncomingMessage({
    required this.endpointId,
    required this.text,
    required this.type,
    this.filePath,
    this.fileName,
  });
}

class NearbyMessageBus {
  static final StreamController<NearbyIncomingMessage> _controller =
      StreamController<NearbyIncomingMessage>.broadcast();

  static Stream<NearbyIncomingMessage> get stream => _controller.stream;

  static void emitText(String endpointId, String text) {
    _controller.add(
      NearbyIncomingMessage(
        endpointId: endpointId,
        text: text,
        type: NearbyIncomingType.text,
      ),
    );
  }

  static void emitFile({
    required String endpointId,
    required String filePath,
    required String fileName,
  }) {
    _controller.add(
      NearbyIncomingMessage(
        endpointId: endpointId,
        text: "📎 Fișier primit: $fileName",
        type: NearbyIncomingType.file,
        filePath: filePath,
        fileName: fileName,
      ),
    );
  }
}

// --- PERMISIUNI NEARBY ---
Future<bool> requestNearbyPermissions() async {
  if (!Platform.isAndroid) return true;

  final statuses = await [
    Permission.locationWhenInUse,
    Permission.bluetoothScan,
    Permission.bluetoothAdvertise,
    Permission.bluetoothConnect,
    Permission.nearbyWifiDevices,
  ].request();

  final locationOk = statuses[Permission.locationWhenInUse]?.isGranted ?? false;
  final scanOk = statuses[Permission.bluetoothScan]?.isGranted ?? true;
  final advertiseOk =
      statuses[Permission.bluetoothAdvertise]?.isGranted ?? true;
  final connectOk = statuses[Permission.bluetoothConnect]?.isGranted ?? true;
  final nearbyWifiOk =
      statuses[Permission.nearbyWifiDevices]?.isGranted ?? true;

  debugPrint("Nearby permissions:");
  debugPrint("LOCATION: $locationOk");
  debugPrint("BT SCAN: $scanOk");
  debugPrint("BT ADVERTISE: $advertiseOk");
  debugPrint("BT CONNECT: $connectOk");
  debugPrint("NEARBY WIFI: $nearbyWifiOk");

  return locationOk && scanOk && advertiseOk && connectOk && nearbyWifiOk;
}

// --- MODELE DE DATE ---
class ChatMessage {
  final String id;
  final String text;
  final bool isMine;
  final DateTime timestamp;

  // "text" sau "file"
  final String type;

  final String? fileName;
  final String? filePath;

  ChatMessage({
    required this.id,
    required this.text,
    required this.isMine,
    required this.timestamp,
    this.type = "text",
    this.fileName,
    this.filePath,
  });

  bool get isFile => type == "file";

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'isMine': isMine,
    'timestamp': timestamp.toIso8601String(),
    'type': type,
    'fileName': fileName,
    'filePath': filePath,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'],
    text: json['text'],
    isMine: json['isMine'],
    timestamp: DateTime.parse(json['timestamp']),
    type: json['type'] ?? "text",
    fileName: json['fileName'],
    filePath: json['filePath'],
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
  String _alias = "MeshChat";
  List<ChatThread> _threads = [];

  SettingsProvider(this._prefs) {
    _isDarkMode = _prefs.getBool('dark_mode') ?? true;
    _saveHistory = _prefs.getBool('save_history') ?? true;
    _accentColor = Color(_prefs.getInt('accent_color') ?? 0xFF0052D4);
    _alias = _prefs.getString('alias') ?? "MeshChat";
    _loadThreads();
  }

  bool get isDarkMode => _isDarkMode;
  bool get saveHistory => _saveHistory;
  Color get accentColor => _accentColor;
  String get alias => _alias;
  List<ChatThread> get threads => _threads;

  void updateAlias(String value) {
    final clean = value.trim();

    if (clean.isEmpty) return;

    _alias = clean;
    _prefs.setString('alias', clean);
    notifyListeners();
  }

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
      try {
        final List decoded = jsonDecode(raw);
        _threads = decoded.map((e) => ChatThread.fromJson(e)).toList();
      } catch (e) {
        debugPrint("Eroare load threads: $e");
        _threads = [];
      }
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
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goToPage(int i) {
    _pageController.animateToPage(
      i,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView(
        controller: _pageController,
        onPageChanged: (i) => setState(() => _idx = i),
        children: [
          const NearbyScannerPage(),
          ChatListPage(onNewChatPressed: () => _goToPage(0)),
          const SettingsPage(),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _idx,
        onTap: _goToPage,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.wifi_tethering),
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
                  child: settings.threads.isEmpty
                      ? const Center(
                          child: Text(
                            "Nu ai conversații încă.\nApasă '+ New Chat' ca să scanezi.",
                            textAlign: TextAlign.center,
                          ),
                        )
                      : ListView.builder(
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
                const SizedBox(height: 80),
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

// --- NEARBY SCAN PAGE ---
class NearbyScannerPage extends StatefulWidget {
  const NearbyScannerPage({super.key});

  @override
  State<NearbyScannerPage> createState() => _NearbyScannerPageState();
}

class _NearbyScannerPageState extends State<NearbyScannerPage> {
  final Strategy _strategy = Strategy.P2P_CLUSTER;

  final Map<String, String> _foundEndpoints = {};
  final Set<String> _connectedEndpoints = {};

  final Map<int, String> _pendingFileNames = {};
  final Map<int, String> _pendingFileUris = {};

  bool _isAdvertising = false;
  bool _isDiscovering = false;

  String _status = "Nearby nu a pornit încă.";
  String _myName = "MeshChat";

  @override
  void initState() {
    super.initState();

    final alias = Provider.of<SettingsProvider>(context, listen: false).alias;
    _myName = "$alias-${DateTime.now().millisecondsSinceEpoch % 10000}";

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startNearby();
    });
  }

  Future<void> _startNearby() async {
    final ok = await requestNearbyPermissions();

    if (!ok) {
      setState(() {
        _status =
            "Permisiuni refuzate. Activează Location / Nearby devices / Wi-Fi.";
      });
      return;
    }

    await _startAdvertising();
    await _startDiscovery();
  }

  Future<void> _startAdvertising() async {
    try {
      final result = await Nearby().startAdvertising(
        _myName,
        _strategy,
        serviceId: kNearbyServiceId,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );

      setState(() {
        _isAdvertising = result;
        _status = result
            ? "Advertising pornit ca $_myName."
            : "Advertising Nearby eșuat.";
      });
    } catch (e) {
      setState(() {
        _isAdvertising = false;
        _status = "Eroare advertising: $e";
      });
    }
  }

  Future<void> _startDiscovery() async {
    try {
      final result = await Nearby().startDiscovery(
        _myName,
        _strategy,
        serviceId: kNearbyServiceId,
        onEndpointFound: (endpointId, endpointName, serviceId) {
          debugPrint("Endpoint found: $endpointId $endpointName $serviceId");

          setState(() {
            _foundEndpoints[endpointId] = endpointName;
            _status = "Găsit: $endpointName";
          });
        },
        onEndpointLost: (endpointId) {
          debugPrint("Endpoint lost: $endpointId");

          setState(() {
            _foundEndpoints.remove(endpointId);
          });
        },
      );

      setState(() {
        _isDiscovering = result;
        if (result) {
          _status = "Discovery pornit. Caut alte telefoane...";
        }
      });
    } catch (e) {
      setState(() {
        _isDiscovering = false;
        _status = "Eroare discovery: $e";
      });
    }
  }

  void _onConnectionInitiated(
    String endpointId,
    ConnectionInfo connectionInfo,
  ) {
    debugPrint(
      "Connection initiated: $endpointId ${connectionInfo.endpointName}",
    );

    Nearby().acceptConnection(
      endpointId,
      onPayLoadRecieved: _onPayloadReceived,
      onPayloadTransferUpdate: (endpointId, update) {
        debugPrint("Payload update from $endpointId: ${update.status}");
      },
    );

    setState(() {
      _foundEndpoints[endpointId] = connectionInfo.endpointName;
      _status = "Conexiune inițiată cu ${connectionInfo.endpointName}.";
    });
  }

  void _onConnectionResult(String endpointId, Status status) {
    debugPrint("Connection result: $endpointId $status");

    final endpointName = _foundEndpoints[endpointId] ?? endpointId;

    if (status == Status.CONNECTED) {
      setState(() {
        _connectedEndpoints.add(endpointId);
        _status = "Conectat cu $endpointName.";
      });

      final thread = ChatThread(
        id: const Uuid().v4(),
        title: endpointName,
        deviceId: endpointId,
        messages: [],
      );

      Provider.of<SettingsProvider>(context, listen: false).saveThread(thread);

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              ModernChatRoom(thread: thread, endpointId: endpointId),
        ),
      );
    } else {
      setState(() {
        _connectedEndpoints.remove(endpointId);
        _status = "Conexiune eșuată cu $endpointName: $status";
      });
    }
  }

  void _onDisconnected(String endpointId) {
    debugPrint("Disconnected: $endpointId");

    setState(() {
      _connectedEndpoints.remove(endpointId);
      _status = "Deconectat: $endpointId";
    });
  }

  Future<void> _saveReceivedFileIfReady({
    required int payloadId,
    required String endpointId,
  }) async {
    final fileName = _pendingFileNames[payloadId];
    final fileUri = _pendingFileUris[payloadId];

    if (fileName == null || fileUri == null) return;

    final dir = await getExternalStorageDirectory();

    if (dir == null) {
      debugPrint("Nu am putut găsi directorul de salvare.");
      return;
    }

    final safeName = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final destinationPath = "${dir.path}/$safeName";

    final copied = await Nearby().copyFileAndDeleteOriginal(
      fileUri,
      destinationPath,
    );

    if (copied) {
      NearbyMessageBus.emitFile(
        endpointId: endpointId,
        filePath: destinationPath,
        fileName: safeName,
      );

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Fișier primit: $safeName")));
      }
    } else {
      debugPrint("Copierea fișierului primit a eșuat.");
    }

    _pendingFileNames.remove(payloadId);
    _pendingFileUris.remove(payloadId);
  }

  void _onPayloadReceived(String endpointId, Payload payload) {
    if (payload.type == PayloadType.BYTES) {
      final bytes = payload.bytes;

      if (bytes == null) return;

      final text = utf8.decode(bytes, allowMalformed: true);

      if (text.startsWith("__FILE__:")) {
        final raw = text.replaceFirst("__FILE__:", "");

        try {
          final data = jsonDecode(raw) as Map<String, dynamic>;

          final payloadId = data["payloadId"] as int;
          final fileName = data["fileName"] as String;

          _pendingFileNames[payloadId] = fileName;

          _saveReceivedFileIfReady(
            payloadId: payloadId,
            endpointId: endpointId,
          );
        } catch (e) {
          debugPrint("Eroare metadata fișier: $e");
        }

        return;
      }

      debugPrint("Message received from $endpointId: $text");

      NearbyMessageBus.emitText(endpointId, text);

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Mesaj primit: $text")));
      }

      return;
    }

    if (payload.type == PayloadType.FILE) {
      final uri = payload.uri;

      if (uri == null) {
        debugPrint("Payload FILE fără uri.");
        return;
      }

      _pendingFileUris[payload.id] = uri;

      _saveReceivedFileIfReady(payloadId: payload.id, endpointId: endpointId);
    }
  }

  Future<void> _connectToEndpoint(String endpointId) async {
    final endpointName = _foundEndpoints[endpointId] ?? endpointId;

    try {
      setState(() {
        _status = "Cer conexiune cu $endpointName...";
      });

      await Nearby().requestConnection(
        _myName,
        endpointId,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
    } catch (e) {
      setState(() {
        _status = "Eroare conectare: $e";
      });
    }
  }

  Future<void> _restartNearby() async {
    await Nearby().stopAdvertising();
    await Nearby().stopDiscovery();

    final alias = Provider.of<SettingsProvider>(context, listen: false).alias;

    setState(() {
      _myName = "$alias-${DateTime.now().millisecondsSinceEpoch % 10000}";
      _foundEndpoints.clear();
      _connectedEndpoints.clear();
      _isAdvertising = false;
      _isDiscovering = false;
      _status = "Restart Nearby...";
    });

    await Future.delayed(const Duration(milliseconds: 500));

    await _startNearby();
  }

  @override
  void dispose() {
    Nearby().stopAdvertising();
    Nearby().stopDiscovery();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final entries = _foundEndpoints.entries.toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text("Nearby Scan"),
        actions: [
          IconButton(
            onPressed: _restartNearby,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Card(
              child: ListTile(
                leading: Icon(
                  _isAdvertising && _isDiscovering
                      ? Icons.wifi_tethering
                      : Icons.wifi_tethering_off,
                  color: _isAdvertising && _isDiscovering
                      ? Colors.green
                      : Colors.orange,
                ),
                title: Text("My name: $_myName"),
                subtitle: Text(_status),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: _startAdvertising,
                    child: Text(
                      _isAdvertising ? "Advertising ON" : "Start Advertising",
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _startDiscovery,
                    child: Text(
                      _isDiscovering ? "Discovery ON" : "Start Discovery",
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: entries.isEmpty
                  ? const Center(
                      child: Text(
                        "Nu am găsit device-uri Nearby încă.\nRulează aplicația pe două telefoane Android reale.",
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final endpointId = entries[index].key;
                        final endpointName = entries[index].value;
                        final isConnected = _connectedEndpoints.contains(
                          endpointId,
                        );

                        return Card(
                          child: ListTile(
                            leading: Icon(
                              isConnected
                                  ? Icons.check_circle
                                  : Icons.phone_android,
                              color: isConnected ? Colors.green : null,
                            ),
                            title: Text(endpointName),
                            subtitle: Text(endpointId),
                            trailing: ElevatedButton(
                              onPressed: isConnected
                                  ? null
                                  : () => _connectToEndpoint(endpointId),
                              child: Text(
                                isConnected ? "Connected" : "Connect",
                              ),
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
  final String? endpointId;

  const ModernChatRoom({super.key, required this.thread, this.endpointId});

  @override
  State<ModernChatRoom> createState() => _ModernChatRoomState();
}

class _ModernChatRoomState extends State<ModernChatRoom> {
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  StreamSubscription<NearbyIncomingMessage>? _nearbySub;

  String _connectionStatus = "Local chat";

  @override
  void initState() {
    super.initState();

    if (widget.endpointId != null) {
      _connectionStatus = "Connected Nearby";

      _nearbySub = NearbyMessageBus.stream.listen((incoming) {
        if (incoming.endpointId != widget.endpointId) return;

        setState(() {
          widget.thread.messages.add(
            ChatMessage(
              id: const Uuid().v4(),
              text: incoming.text,
              isMine: false,
              timestamp: DateTime.now(),
              type: incoming.type == NearbyIncomingType.file ? "file" : "text",
              fileName: incoming.fileName,
              filePath: incoming.filePath,
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

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;

      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  bool _isImageFile(String? fileName) {
    if (fileName == null) return false;

    final lower = fileName.toLowerCase();

    return lower.endsWith(".jpg") ||
        lower.endsWith(".jpeg") ||
        lower.endsWith(".png") ||
        lower.endsWith(".gif") ||
        lower.endsWith(".webp") ||
        lower.endsWith(".bmp");
  }

  bool _isVideoFile(String? fileName) {
    if (fileName == null) return false;

    final lower = fileName.toLowerCase();

    return lower.endsWith(".mp4") ||
        lower.endsWith(".mov") ||
        lower.endsWith(".mkv") ||
        lower.endsWith(".webm") ||
        lower.endsWith(".avi");
  }

  Future<void> _openFile(ChatMessage message) async {
    final path = message.filePath;

    if (path == null || path.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Nu am cale pentru fișier.")),
      );
      return;
    }

    final file = File(path);

    if (!await file.exists()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Fișierul nu mai există pe dispozitiv.")),
      );
      return;
    }

    await OpenFilex.open(path);
  }

  Future<void> _downloadFile(ChatMessage message) async {
    final sourcePath = message.filePath;
    final fileName = message.fileName ?? "meshup_file";

    if (sourcePath == null || sourcePath.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Nu am cale pentru fișier.")),
      );
      return;
    }

    final sourceFile = File(sourcePath);

    if (!await sourceFile.exists()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Fișierul nu mai există pe dispozitiv.")),
      );
      return;
    }

    try {
      final bytes = await sourceFile.readAsBytes();

      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: "Salvează fișierul",
        fileName: fileName,
        bytes: bytes,
      );

      if (savedPath == null) return;

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Fișier salvat: $fileName")));
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Eroare la salvare: $e")));
    }
  }

  Widget _buildFileBubble(ChatMessage message) {
    final fileName = message.fileName ?? "Fișier";
    final filePath = message.filePath;
    final fileExists = filePath != null && File(filePath).existsSync();

    final imagePreview = fileExists && _isImageFile(fileName);
    final videoPreview = _isVideoFile(fileName);

    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.all(10),
      margin: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: message.isMine
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (imagePreview)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.file(
                File(filePath),
                height: 180,
                width: 260,
                fit: BoxFit.cover,
              ),
            )
          else
            Container(
              height: 120,
              width: 260,
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                videoPreview ? Icons.videocam : Icons.insert_drive_file,
                size: 46,
                color: message.isMine ? Colors.white : null,
              ),
            ),
          const SizedBox(height: 8),
          Text(
            fileName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: message.isMine ? Colors.white : null,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton.icon(
                onPressed: fileExists ? () => _openFile(message) : null,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text("Open"),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: fileExists ? () => _downloadFile(message) : null,
                icon: const Icon(Icons.download, size: 16),
                label: const Text("Save"),
              ),
            ],
          ),
          if (!fileExists)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                "Fișier indisponibil local",
                style: TextStyle(
                  fontSize: 12,
                  color: message.isMine ? Colors.white70 : Colors.red,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _sendFile() async {
    if (widget.endpointId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Conectează-te la un device înainte să trimiți fișiere.",
          ),
        ),
      );
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: false,
    );

    if (result == null || result.files.isEmpty) return;

    final picked = result.files.single;
    final path = picked.path;

    if (path == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Nu pot accesa calea fișierului.")),
      );
      return;
    }

    try {
      final payloadId = await Nearby().sendFilePayload(
        widget.endpointId!,
        path,
      );

      final fileName = picked.name;

      final metadata = {
        "payloadId": payloadId,
        "fileName": fileName,
        "size": picked.size,
      };

      await Nearby().sendBytesPayload(
        widget.endpointId!,
        Uint8List.fromList(utf8.encode("__FILE__:${jsonEncode(metadata)}")),
      );

      setState(() {
        widget.thread.messages.add(
          ChatMessage(
            id: const Uuid().v4(),
            text: "📎 Fișier trimis: $fileName",
            isMine: true,
            timestamp: DateTime.now(),
            type: "file",
            fileName: fileName,
            filePath: path,
          ),
        );
      });

      _scrollToBottom();

      Provider.of<SettingsProvider>(
        context,
        listen: false,
      ).saveThread(widget.thread);
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text("Eroare trimitere fișier: $e")));
    }
  }

  Future<void> _send() async {
    if (_msgController.text.trim().isEmpty) return;

    final text = _msgController.text.trim();

    setState(() {
      widget.thread.messages.add(
        ChatMessage(
          id: const Uuid().v4(),
          text: text,
          isMine: true,
          timestamp: DateTime.now(),
        ),
      );
    });

    _scrollToBottom();

    if (widget.endpointId != null) {
      try {
        await Nearby().sendBytesPayload(
          widget.endpointId!,
          Uint8List.fromList(utf8.encode(text)),
        );
      } catch (e) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text("Eroare trimitere Nearby: $e")));
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Chat salvat local. Pentru trimitere reală conectează-te din pagina Scan.",
          ),
        ),
      );
    }

    _msgController.clear();

    Provider.of<SettingsProvider>(
      context,
      listen: false,
    ).saveThread(widget.thread);
  }

  @override
  void dispose() {
    _nearbySub?.cancel();
    _msgController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canSendNearby = widget.endpointId != null;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.thread.title),
            Text(_connectionStatus, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            color: canSendNearby
                ? Colors.green.withOpacity(0.15)
                : Colors.orange.withOpacity(0.15),
            child: Text(
              canSendNearby
                  ? "Nearby ready: mesajele și fișierele se trimit către device-ul conectat."
                  : "Chat local. Pentru mesaje live, conectează-te din Scan.",
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          Expanded(
            child: widget.thread.messages.isEmpty
                ? const Center(child: Text("Nu există mesaje încă."))
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: widget.thread.messages.length,
                    itemBuilder: (context, i) {
                      final message = widget.thread.messages[i];

                      return Align(
                        alignment: message.isMine
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: message.isFile
                            ? _buildFileBubble(message)
                            : Container(
                                padding: const EdgeInsets.all(12),
                                margin: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: message.isMine
                                      ? Theme.of(context).colorScheme.primary
                                      : Theme.of(context).cardColor,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  message.text,
                                  style: TextStyle(
                                    color: message.isMine ? Colors.white : null,
                                  ),
                                ),
                              ),
                      );
                    },
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _msgController,
                      decoration: const InputDecoration(
                        hintText: "Mesaj...",
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _send(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _sendFile,
                    icon: const Icon(Icons.attach_file),
                  ),
                  IconButton.filled(
                    onPressed: _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// --- SETTINGS ---
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _aliasController;

  @override
  void initState() {
    super.initState();

    final settings = Provider.of<SettingsProvider>(context, listen: false);
    _aliasController = TextEditingController(text: settings.alias);
  }

  @override
  void dispose() {
    _aliasController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: CircleAvatar(
              backgroundColor: settings.accentColor,
              child: const Text('ME'),
            ),
            title: const Text('My Device'),
            subtitle: Text(
              "${settings.alias} • ${Platform.isAndroid ? "Android Node" : "iOS Node"}",
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Alias Nearby",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _aliasController,
                    decoration: const InputDecoration(
                      labelText: "Numele meu",
                      hintText: "Ex: Alex, Dva, Telefonul meu",
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (value) {
                      settings.updateAlias(value);

                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            "Alias salvat. Revino în Scan și apasă refresh.",
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () {
                        settings.updateAlias(_aliasController.text);

                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text(
                              "Alias salvat. Revino în Scan și apasă refresh.",
                            ),
                          ),
                        );
                      },
                      child: const Text("Salvează alias"),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    "După schimbare, revino în Scan și apasă refresh ca să repornească Nearby cu noul nume.",
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          SwitchListTile(
            title: const Text("Save History"),
            value: settings.saveHistory,
            onChanged: (v) => settings.toggleSaveHistory(v),
          ),
          ListTile(
            leading: const Icon(Icons.delete, color: Colors.red),
            title: const Text("Clear Chats"),
            onTap: () => settings.clearChats(),
          ),
          SwitchListTile(
            title: const Text("Dark Mode"),
            value: settings.isDarkMode,
            onChanged: (v) => settings.toggleTheme(v),
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
                ].map((color) {
                  return GestureDetector(
                    onTap: () => settings.updateAccent(color),
                    child: CircleAvatar(
                      backgroundColor: color,
                      radius: 18,
                      child: settings.accentColor.value == color.value
                          ? const Icon(Icons.check, color: Colors.white)
                          : null,
                    ),
                  );
                }).toList(),
          ),
        ],
      ),
    );
  }
}
