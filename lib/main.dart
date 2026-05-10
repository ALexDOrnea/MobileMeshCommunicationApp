import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const String kNearbyServiceId = "com.meshup.chat";
const String kEndpointSeparator = "::";
const String kGroupInviteSeparator = "::GROUPINVITE::";

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppNotifications.init();
  final prefs = await SharedPreferences.getInstance();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => SettingsProvider(prefs)),
        ChangeNotifierProvider(create: (_) => NearbyProvider(prefs)..start()),
      ],
      child: const MeshChatApp(),
    ),
  );
}

// --- NOTIFICĂRI LOCALE ---
class AppNotifications {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static const AndroidNotificationChannel _androidChannel =
      AndroidNotificationChannel(
        'meshchat_messages',
        'MeshChat Messages',
        description: 'Notifications for messages received via Nearby',
        importance: Importance.high,
      );

  static Future<void> init() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidInit);

    await _plugin.initialize(initSettings);

    final androidPlugin = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidPlugin?.createNotificationChannel(_androidChannel);
  }

  static Future<bool> requestPermission() async {
    if (!Platform.isAndroid) return true;

    final status = await Permission.notification.request();
    return status.isGranted;
  }

  static Future<void> showMessage({
    required String title,
    required String body,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'meshchat_messages',
      'MeshChat Messages',
      channelDescription: 'Notifications for messages received via Nearby',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/ic_launcher',
    );

    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      title,
      body,
      details,
    );
  }
}

// --- PERMISIUNI ---
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

Future<bool> requestMicrophonePermission() async {
  if (!Platform.isAndroid && !Platform.isIOS) return true;

  final status = await Permission.microphone.request();
  return status.isGranted;
}

// --- MODELE DE DATE ---
class ChatMessage {
  final String id;
  final String text;
  final bool isMine;
  final DateTime timestamp;
  final String type;
  final String? fileName;
  final String? filePath;
  final String? senderNodeId;
  final String? senderName;

  ChatMessage({
    required this.id,
    required this.text,
    required this.isMine,
    required this.timestamp,
    this.type = "text",
    this.fileName,
    this.filePath,
    this.senderNodeId,
    this.senderName,
  });

  bool get isFile => type == "file";
  bool get isVoice => type == "voice";

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'isMine': isMine,
    'timestamp': timestamp.toIso8601String(),
    'type': type,
    'fileName': fileName,
    'filePath': filePath,
    'senderNodeId': senderNodeId,
    'senderName': senderName,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    id: json['id'],
    text: json['text'],
    isMine: json['isMine'],
    timestamp: DateTime.parse(json['timestamp']),
    type: json['type'] ?? "text",
    fileName: json['fileName'],
    filePath: json['filePath'],
    senderNodeId: json['senderNodeId'],
    senderName: json['senderName'],
  );
}

class ChatThread {
  final String id;
  String title;

  /// Pentru 1-la-1: ID-ul permanent al celuilalt telefon.
  /// Pentru grupuri: null.
  final String? deviceId;

  final bool isGroup;
  final List<String> participantNodeIds;
  final Map<String, String> participantNames;

  List<ChatMessage> messages;

  ChatThread({
    required this.id,
    required this.title,
    this.deviceId,
    this.isGroup = false,
    List<String>? participantNodeIds,
    Map<String, String>? participantNames,
    required this.messages,
  }) : participantNodeIds =
           participantNodeIds ??
           (deviceId == null ? <String>[] : <String>[deviceId]),
       participantNames = participantNames ?? {};

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'deviceId': deviceId,
    'isGroup': isGroup,
    'participantNodeIds': participantNodeIds,
    'participantNames': participantNames,
    'messages': messages.map((e) => e.toJson()).toList(),
  };

  factory ChatThread.fromJson(Map<String, dynamic> json) => ChatThread(
    id: json['id'],
    title: json['title'],
    deviceId: json['deviceId'],
    isGroup: json['isGroup'] ?? false,
    participantNodeIds:
        ((json['participantNodeIds'] as List?) ??
                (json['deviceId'] == null ? const [] : [json['deviceId']]))
            .map((e) => e.toString())
            .toList(),
    participantNames: Map<String, String>.from(json['participantNames'] ?? {}),
    messages: (json['messages'] as List)
        .map((e) => ChatMessage.fromJson(e))
        .toList(),
  );
}

class NearbyDevice {
  final String endpointId;
  final String nodeId;
  final String displayName;

  NearbyDevice({
    required this.endpointId,
    required this.nodeId,
    required this.displayName,
  });
}

class NearbyConnectionRequest {
  final String endpointId;
  final String nodeId;
  final String displayName;

  final bool isGroupInvite;
  final String? groupId;
  final String? groupTitle;
  final List<String> participantNodeIds;
  final Map<String, String> participantNames;

  NearbyConnectionRequest({
    required this.endpointId,
    required this.nodeId,
    required this.displayName,
    this.isGroupInvite = false,
    this.groupId,
    this.groupTitle,
    this.participantNodeIds = const [],
    this.participantNames = const {},
  });
}

enum NearbyIncomingType { text, file, voice }

class NearbyGroupInvite {
  final String endpointId;
  final String groupId;
  final String groupTitle;
  final String inviterNodeId;
  final String inviterName;
  final List<String> participantNodeIds;
  final Map<String, String> participantNames;

  NearbyGroupInvite({
    required this.endpointId,
    required this.groupId,
    required this.groupTitle,
    required this.inviterNodeId,
    required this.inviterName,
    required this.participantNodeIds,
    required this.participantNames,
  });
}

class NearbyIncomingMessage {
  final String endpointId;
  final String nodeId;
  final String displayName;
  final String text;
  final NearbyIncomingType type;
  final String? filePath;
  final String? fileName;
  final String? groupId;
  final String? senderNodeId;
  final String? senderName;

  NearbyIncomingMessage({
    required this.endpointId,
    required this.nodeId,
    required this.displayName,
    required this.text,
    required this.type,
    this.filePath,
    this.fileName,
    this.groupId,
    this.senderNodeId,
    this.senderName,
  });
}

class ParsedEndpointName {
  final String displayName;
  final String nodeId;

  ParsedEndpointName({required this.displayName, required this.nodeId});
}

ParsedEndpointName parseEndpointName(String raw) {
  if (raw.contains(kGroupInviteSeparator)) {
    raw = raw.split(kGroupInviteSeparator).first;
  }
  if (!raw.contains(kEndpointSeparator)) {
    return ParsedEndpointName(displayName: raw, nodeId: raw);
  }

  final parts = raw.split(kEndpointSeparator);
  final nodeId = parts.removeLast();
  final displayName = parts.join(kEndpointSeparator).trim();

  return ParsedEndpointName(
    displayName: displayName.isEmpty ? "MeshChat" : displayName,
    nodeId: nodeId,
  );
}

// --- PROVIDER SETĂRI / ISTORIC ---
class SettingsProvider extends ChangeNotifier {
  final SharedPreferences _prefs;

  bool _isDarkMode = true;
  bool _saveHistory = true;
  bool _notificationsEnabled = true;
  Color _accentColor = const Color(0xFF0052D4);
  String _alias = "MeshChat";
  List<ChatThread> _threads = [];

  SettingsProvider(this._prefs) {
    _isDarkMode = _prefs.getBool('dark_mode') ?? true;
    _saveHistory = _prefs.getBool('save_history') ?? true;
    _notificationsEnabled = _prefs.getBool('notifications_enabled') ?? true;
    _accentColor = Color(_prefs.getInt('accent_color') ?? 0xFF0052D4);
    _alias = _prefs.getString('alias') ?? "MeshChat";
    _loadThreads();
  }

  bool get isDarkMode => _isDarkMode;
  bool get saveHistory => _saveHistory;
  bool get notificationsEnabled => _notificationsEnabled;
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

  Future<void> toggleNotifications(bool val) async {
    if (val) {
      final ok = await AppNotifications.requestPermission();
      if (!ok) return;
    }

    _notificationsEnabled = val;
    _prefs.setBool('notifications_enabled', val);
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

  void _persistThreads() {
    if (!_saveHistory) return;

    _prefs.setString(
      'chat_threads',
      jsonEncode(_threads.map((e) => e.toJson()).toList()),
    );
  }

  ChatThread? threadById(String id) {
    try {
      return _threads.firstWhere((t) => t.id == id);
    } catch (_) {
      return null;
    }
  }

  ChatThread? threadByDeviceId(String deviceId) {
    try {
      return _threads.firstWhere((t) => !t.isGroup && t.deviceId == deviceId);
    } catch (_) {
      return null;
    }
  }

  ChatThread getOrCreateThreadForDevice({
    required String deviceId,
    required String title,
  }) {
    final existing = threadByDeviceId(deviceId);

    if (existing != null) {
      if (existing.title != title && title.trim().isNotEmpty) {
        existing.title = title;
        existing.participantNames[deviceId] = title;
        _persistThreads();
        notifyListeners();
      }
      return existing;
    }

    final thread = ChatThread(
      id: const Uuid().v4(),
      title: title,
      deviceId: deviceId,
      isGroup: false,
      participantNodeIds: [deviceId],
      participantNames: {deviceId: title},
      messages: [],
    );

    _threads.insert(0, thread);
    _persistThreads();
    notifyListeners();
    return thread;
  }

  ChatThread createGroupThread({
    required String title,
    required List<String> participantNodeIds,
    required Map<String, String> participantNames,
    String? groupId,
  }) {
    final id = groupId ?? const Uuid().v4();
    final existing = threadById(id);
    if (existing != null) return existing;

    final thread = ChatThread(
      id: id,
      title: title.trim().isEmpty ? "Meshchat Group" : title.trim(),
      isGroup: true,
      participantNodeIds: participantNodeIds.toSet().toList(),
      participantNames: participantNames,
      messages: [],
    );

    _threads.insert(0, thread);
    _persistThreads();
    notifyListeners();
    return thread;
  }

  void saveThread(ChatThread thread) {
    if (!_saveHistory) return;

    _threads.removeWhere((t) => t.id == thread.id);
    _threads.insert(0, thread);
    _persistThreads();
    notifyListeners();
  }

  void addMessageToThreadId(String threadId, ChatMessage message) {
    final thread = threadById(threadId);
    if (thread == null) return;

    thread.messages.add(message);
    saveThread(thread);
  }

  ChatThread addIncomingMessage({
    required String deviceId,
    required String title,
    required ChatMessage message,
  }) {
    final thread = getOrCreateThreadForDevice(deviceId: deviceId, title: title);
    thread.messages.add(message);
    saveThread(thread);
    return thread;
  }

  void deleteThread(String threadId) {
    _threads.removeWhere((t) => t.id == threadId);
    _persistThreads();
    notifyListeners();
  }

  void clearChats() {
    _threads.clear();
    _prefs.remove('chat_threads');
    notifyListeners();
  }
}

// --- NEARBY GLOBAL PROVIDER ---
class NearbyProvider extends ChangeNotifier with WidgetsBindingObserver {
  final SharedPreferences _prefs;
  final Strategy _strategy = Strategy.P2P_CLUSTER;

  final Map<String, NearbyDevice> _devicesByEndpoint = {};
  final Map<String, String> _connectedEndpointByNodeId = {};
  final Map<int, String> _pendingFileNames = {};
  final Map<int, String> _pendingFileUris = {};
  final Map<int, String> _pendingFileKinds = {};
  final Map<int, String> _pendingFileGroupIds = {};
  final Map<int, String> _pendingFileSenderNodeIds = {};
  final Map<int, String> _pendingFileSenderNames = {};

  final StreamController<NearbyIncomingMessage> _incomingController =
      StreamController<NearbyIncomingMessage>.broadcast();
  final StreamController<NearbyConnectionRequest> _connectionRequestController =
      StreamController<NearbyConnectionRequest>.broadcast();
  final StreamController<NearbyGroupInvite> _groupInviteController =
      StreamController<NearbyGroupInvite>.broadcast();

  bool _isAdvertising = false;
  bool _isDiscovering = false;
  bool _isStarting = false;
  String _status = "Nearby is not running yet.";

  late final String _localNodeId;

  NearbyProvider(this._prefs) {
    WidgetsBinding.instance.addObserver(this);
    _localNodeId = _prefs.getString('local_node_id') ?? const Uuid().v4();
    _prefs.setString('local_node_id', _localNodeId);
  }

  String get localNodeId => _localNodeId;
  bool get isAdvertising => _isAdvertising;
  bool get isDiscovering => _isDiscovering;
  String get status => _status;

  List<NearbyDevice> get discoveredDevices =>
      _devicesByEndpoint.values.toList();
  Stream<NearbyIncomingMessage> get incomingMessages =>
      _incomingController.stream;
  Stream<NearbyConnectionRequest> get connectionRequests =>
      _connectionRequestController.stream;
  Stream<NearbyGroupInvite> get groupInvites => _groupInviteController.stream;

  String advertisingName(String alias) =>
      "$alias$kEndpointSeparator$_localNodeId";

  String groupInviteConnectionName({
    required String alias,
    required ChatThread groupThread,
  }) {
    final payload = jsonEncode({
      "groupId": groupThread.id,
      "groupTitle": groupThread.title,
      "participantNodeIds": groupThread.participantNodeIds,
      "participantNames": groupThread.participantNames,
    });

    final encoded = base64UrlEncode(utf8.encode(payload));
    return "${advertisingName(alias)}$kGroupInviteSeparator$encoded";
  }

  bool isDeviceOnline(String? nodeId) {
    if (nodeId == null) return false;
    return _devicesByEndpoint.values.any((d) => d.nodeId == nodeId) ||
        _connectedEndpointByNodeId.containsKey(nodeId);
  }

  bool isDeviceConnected(String? nodeId) {
    if (nodeId == null) return false;
    return _connectedEndpointByNodeId.containsKey(nodeId);
  }

  NearbyDevice? deviceByNodeId(String? nodeId) {
    if (nodeId == null) return null;
    for (final device in _devicesByEndpoint.values) {
      if (device.nodeId == nodeId) return device;
    }
    return null;
  }

  NearbyDevice? deviceByEndpointId(String endpointId) {
    return _devicesByEndpoint[endpointId];
  }

  List<NearbyDevice> onlineGroupCandidates() => discoveredDevices;

  int activeCountForThread(ChatThread thread) {
    if (!thread.isGroup) return isDeviceConnected(thread.deviceId) ? 1 : 0;
    return thread.participantNodeIds.where(isDeviceConnected).length;
  }

  List<String> activeNamesForThread(ChatThread thread) {
    if (!thread.isGroup) {
      if (!isDeviceConnected(thread.deviceId)) return [];
      return [thread.title];
    }

    return thread.participantNodeIds
        .where(isDeviceConnected)
        .map(
          (id) =>
              thread.participantNames[id] ??
              deviceByNodeId(id)?.displayName ??
              id,
        )
        .toList();
  }

  Future<void> start() async {
    if (_isStarting) return;
    _isStarting = true;

    final ok = await requestNearbyPermissions();

    if (!ok) {
      _status = "Permissions denied. Enable Location / Nearby devices / Wi-Fi.";
      _isStarting = false;
      notifyListeners();
      return;
    }

    await startAdvertising();
    await startDiscovery();

    _isStarting = false;
  }

  Future<void> startAdvertising() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final alias = prefs.getString('alias') ?? "MeshChat";

      final result = await Nearby().startAdvertising(
        advertisingName(alias),
        _strategy,
        serviceId: kNearbyServiceId,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );

      _isAdvertising = result;
      _status = result
          ? "Advertising started as $alias."
          : "Advertising Nearby failed.";
      notifyListeners();
    } catch (e) {
      _isAdvertising = false;
      _status = "Error advertising: $e";
      notifyListeners();
    }
  }

  Future<void> startDiscovery() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final alias = prefs.getString('alias') ?? "MeshChat";

      final result = await Nearby().startDiscovery(
        advertisingName(alias),
        _strategy,
        serviceId: kNearbyServiceId,
        onEndpointFound: (endpointId, endpointName, serviceId) {
          final parsed = parseEndpointName(endpointName);

          if (parsed.nodeId == _localNodeId) return;

          _devicesByEndpoint[endpointId] = NearbyDevice(
            endpointId: endpointId,
            nodeId: parsed.nodeId,
            displayName: parsed.displayName,
          );

          _status = "Găsit: ${parsed.displayName}";
          notifyListeners();
        },
        onEndpointLost: (endpointId) {
          final device = _devicesByEndpoint.remove(endpointId);
          if (device != null) {
            _connectedEndpointByNodeId.remove(device.nodeId);
          }
          notifyListeners();
        },
      );

      _isDiscovering = result;
      if (result) _status = "Discovery started. Looking for other devices...";
      notifyListeners();
    } catch (e) {
      _isDiscovering = false;
      _status = "Error discovery: $e";
      notifyListeners();
    }
  }

  void _onConnectionInitiated(
    String endpointId,
    ConnectionInfo connectionInfo,
  ) {
    final rawName = connectionInfo.endpointName;
    final parsed = parseEndpointName(rawName);

    bool isGroupInvite = false;
    String? groupId;
    String? groupTitle;
    List<String> participantNodeIds = [];
    Map<String, String> participantNames = {};

    if (rawName.contains(kGroupInviteSeparator)) {
      try {
        final encoded = rawName.split(kGroupInviteSeparator).last;
        final data =
            jsonDecode(utf8.decode(base64Url.decode(encoded)))
                as Map<String, dynamic>;
        isGroupInvite = true;
        groupId = data["groupId"] as String?;
        groupTitle = data["groupTitle"] as String?;
        participantNodeIds = ((data["participantNodeIds"] as List?) ?? const [])
            .map((e) => e.toString())
            .toList();
        participantNames = Map<String, String>.from(
          data["participantNames"] ?? {},
        );
      } catch (e) {
        debugPrint("Error parsing group invite connection name: $e");
      }
    }

    _devicesByEndpoint[endpointId] = NearbyDevice(
      endpointId: endpointId,
      nodeId: parsed.nodeId,
      displayName: parsed.displayName,
    );

    _status = isGroupInvite
        ? "Group invite from ${parsed.displayName}."
        : "Connection request from ${parsed.displayName}.";
    notifyListeners();

    _connectionRequestController.add(
      NearbyConnectionRequest(
        endpointId: endpointId,
        nodeId: parsed.nodeId,
        displayName: parsed.displayName,
        isGroupInvite: isGroupInvite,
        groupId: groupId,
        groupTitle: groupTitle,
        participantNodeIds: participantNodeIds,
        participantNames: participantNames,
      ),
    );
  }

  Future<void> acceptConnection(String endpointId) async {
    try {
      await Nearby().acceptConnection(
        endpointId,
        onPayLoadRecieved: _onPayloadReceived,
        onPayloadTransferUpdate: (endpointId, update) {
          debugPrint("Payload update from $endpointId: ${update.status}");
        },
      );

      final device = _devicesByEndpoint[endpointId];
      if (device != null) {
        _status = "Connection accepted with ${device.displayName}.";
      }
      notifyListeners();
    } catch (e) {
      _status = "Error accepting connection: $e";
      notifyListeners();
    }
  }

  Future<void> rejectConnection(String endpointId) async {
    try {
      await Nearby().rejectConnection(endpointId);
      _status = "Connection rejected.";
      notifyListeners();
    } catch (e) {
      _status = "Error rejecting connection: $e";
      notifyListeners();
    }
  }

  void _onConnectionResult(String endpointId, Status status) {
    final device = _devicesByEndpoint[endpointId];
    final name = device?.displayName ?? endpointId;

    if (status == Status.CONNECTED) {
      if (device != null) {
        _connectedEndpointByNodeId[device.nodeId] = endpointId;
      }
      _status = "Connected to $name.";
    } else {
      if (device != null) {
        _connectedEndpointByNodeId.remove(device.nodeId);
      }
      _status = "Connection failed with $name: $status";
    }

    notifyListeners();
  }

  void _onDisconnected(String endpointId) {
    final device = _devicesByEndpoint[endpointId];
    if (device != null) {
      _connectedEndpointByNodeId.remove(device.nodeId);
      _status = "Disconnected: ${device.displayName}";
    } else {
      _status = "Disconnected: $endpointId";
    }
    notifyListeners();
  }

  Future<void> connectToDevice(String nodeId) async {
    final device = deviceByNodeId(nodeId);

    if (device == null) {
      _status = "Device not online";
      notifyListeners();
      return;
    }

    try {
      _status = "Connection requested with ${device.displayName}...";
      notifyListeners();

      await Nearby().requestConnection(
        advertisingName(_prefs.getString('alias') ?? "MeshChat"),
        device.endpointId,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
    } catch (e) {
      _status = "Error connecting: $e";
      notifyListeners();
    }
  }

  Future<void> disconnectDevice(String nodeId) async {
    final endpointId = _connectedEndpointByNodeId[nodeId];
    if (endpointId == null) return;

    try {
      await Nearby().disconnectFromEndpoint(endpointId);
    } catch (_) {}

    _connectedEndpointByNodeId.remove(nodeId);
    _status = "Disconnected.";
    notifyListeners();
  }

  Future<void> connectThreadDevices(ChatThread thread) async {
    if (!thread.isGroup) {
      final nodeId = thread.deviceId;
      if (nodeId != null &&
          !isDeviceConnected(nodeId) &&
          isDeviceOnline(nodeId)) {
        await connectToDevice(nodeId);
      }
      return;
    }

    for (final nodeId in thread.participantNodeIds) {
      if (!isDeviceConnected(nodeId) && isDeviceOnline(nodeId)) {
        await connectToDevice(nodeId);
        await Future.delayed(const Duration(milliseconds: 500));
      }
    }
  }

  Future<void> restartNearby() async {
    try {
      await Nearby().stopAdvertising();
      await Nearby().stopDiscovery();
    } catch (_) {}

    _devicesByEndpoint.clear();
    _connectedEndpointByNodeId.clear();
    _isAdvertising = false;
    _isDiscovering = false;
    _status = "Restart Nearby...";
    notifyListeners();

    await Future.delayed(const Duration(milliseconds: 500));
    await start();
  }

  Future<void> sendGroupInvite({
    required ChatThread groupThread,
    required List<String> targetNodeIds,
  }) async {
    final alias = _prefs.getString('alias') ?? "MeshChat";

    for (final nodeId in targetNodeIds) {
      if (!isDeviceConnected(nodeId) && isDeviceOnline(nodeId)) {
        final device = deviceByNodeId(nodeId);
        if (device != null) {
          try {
            await Nearby().requestConnection(
              groupInviteConnectionName(alias: alias, groupThread: groupThread),
              device.endpointId,
              onConnectionInitiated: _onConnectionInitiated,
              onConnectionResult: _onConnectionResult,
              onDisconnected: _onDisconnected,
            );
          } catch (e) {
            _status = "Error sending group invite: $e";
            notifyListeners();
          }
        }
        await Future.delayed(const Duration(seconds: 1));
      }

      final endpointId = _connectedEndpointByNodeId[nodeId];
      if (endpointId == null) continue;

      final payload = {
        "groupId": groupThread.id,
        "groupTitle": groupThread.title,
        "inviterNodeId": _localNodeId,
        "inviterName": alias,
        "participantNodeIds": groupThread.participantNodeIds,
        "participantNames": groupThread.participantNames,
      };

      await Nearby().sendBytesPayload(
        endpointId,
        Uint8List.fromList(
          utf8.encode("__GROUP_INVITE__:${jsonEncode(payload)}"),
        ),
      );
    }
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
      debugPrint("Could not find the save directory.");
      return;
    }

    final kind = _pendingFileKinds[payloadId] ?? "file";
    final groupId = _pendingFileGroupIds[payloadId];
    final senderNodeId = _pendingFileSenderNodeIds[payloadId];
    final senderName = _pendingFileSenderNames[payloadId];
    final safeName = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final destinationPath = "${dir.path}/$safeName";

    final copied = await Nearby().copyFileAndDeleteOriginal(
      fileUri,
      destinationPath,
    );

    final device = _devicesByEndpoint[endpointId];
    final nodeId = device?.nodeId ?? endpointId;
    final displayName = device?.displayName ?? endpointId;

    if (copied) {
      _incomingController.add(
        NearbyIncomingMessage(
          endpointId: endpointId,
          nodeId: senderNodeId ?? nodeId,
          displayName: senderName ?? displayName,
          text: kind == "voice"
              ? "🎤 Mesaj vocal"
              : "📎 Fișier primit: $safeName",
          type: kind == "voice"
              ? NearbyIncomingType.voice
              : NearbyIncomingType.file,
          filePath: destinationPath,
          fileName: safeName,
          groupId: groupId,
          senderNodeId: senderNodeId ?? nodeId,
          senderName: senderName ?? displayName,
        ),
      );
    } else {
      debugPrint("Failed to copy the received file.");
    }

    _pendingFileNames.remove(payloadId);
    _pendingFileUris.remove(payloadId);
    _pendingFileKinds.remove(payloadId);
    _pendingFileGroupIds.remove(payloadId);
    _pendingFileSenderNodeIds.remove(payloadId);
    _pendingFileSenderNames.remove(payloadId);
  }

  void _onPayloadReceived(String endpointId, Payload payload) {
    final device = _devicesByEndpoint[endpointId];
    final nodeId = device?.nodeId ?? endpointId;
    final displayName = device?.displayName ?? endpointId;

    if (payload.type == PayloadType.BYTES) {
      final bytes = payload.bytes;
      if (bytes == null) return;

      final text = utf8.decode(bytes, allowMalformed: true);

      if (text.startsWith("__GROUP_INVITE__:")) {
        final raw = text.replaceFirst("__GROUP_INVITE__:", "");

        try {
          final data = jsonDecode(raw) as Map<String, dynamic>;
          _groupInviteController.add(
            NearbyGroupInvite(
              endpointId: endpointId,
              groupId: data["groupId"] as String,
              groupTitle: data["groupTitle"] as String,
              inviterNodeId: data["inviterNodeId"] as String,
              inviterName: data["inviterName"] as String,
              participantNodeIds:
                  ((data["participantNodeIds"] as List?) ?? const [])
                      .map((e) => e.toString())
                      .toList(),
              participantNames: Map<String, String>.from(
                data["participantNames"] ?? {},
              ),
            ),
          );
        } catch (e) {
          debugPrint("Error sending group invite: $e");
        }
        return;
      }

      if (text.startsWith("__CHAT__:")) {
        final raw = text.replaceFirst("__CHAT__:", "");

        try {
          final data = jsonDecode(raw) as Map<String, dynamic>;
          _incomingController.add(
            NearbyIncomingMessage(
              endpointId: endpointId,
              nodeId: data["senderNodeId"] as String? ?? nodeId,
              displayName: data["senderName"] as String? ?? displayName,
              text: data["text"] as String? ?? "",
              type: NearbyIncomingType.text,
              groupId: data["groupId"] as String?,
              senderNodeId: data["senderNodeId"] as String? ?? nodeId,
              senderName: data["senderName"] as String? ?? displayName,
            ),
          );
        } catch (e) {
          debugPrint("Error sending group invite: $e");
        }
        return;
      }

      if (text.startsWith("__FILE__:")) {
        final raw = text.replaceFirst("__FILE__:", "");

        try {
          final data = jsonDecode(raw) as Map<String, dynamic>;
          final payloadId = data["payloadId"] as int;
          final fileName = data["fileName"] as String;
          final kind = (data["kind"] as String?) ?? "file";
          final groupId = data["groupId"] as String?;
          final senderNodeId = data["senderNodeId"] as String?;
          final senderName = data["senderName"] as String?;

          _pendingFileNames[payloadId] = fileName;
          _pendingFileKinds[payloadId] = kind;
          if (groupId != null) _pendingFileGroupIds[payloadId] = groupId;
          if (senderNodeId != null)
            _pendingFileSenderNodeIds[payloadId] = senderNodeId;
          if (senderName != null)
            _pendingFileSenderNames[payloadId] = senderName;

          _saveReceivedFileIfReady(
            payloadId: payloadId,
            endpointId: endpointId,
          );
        } catch (e) {
          debugPrint("Error with file metadata: $e");
        }
        return;
      }

      _incomingController.add(
        NearbyIncomingMessage(
          endpointId: endpointId,
          nodeId: nodeId,
          displayName: displayName,
          text: text,
          type: NearbyIncomingType.text,
          senderNodeId: nodeId,
          senderName: displayName,
        ),
      );
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

  Future<bool> sendTextToDevice(String nodeId, String text) async {
    final endpointId = _connectedEndpointByNodeId[nodeId];
    if (endpointId == null) {
      _status = "Device-ul nu este conectat.";
      notifyListeners();
      return false;
    }

    try {
      await Nearby().sendBytesPayload(
        endpointId,
        Uint8List.fromList(utf8.encode(text)),
      );
      return true;
    } catch (e) {
      _status = "Eroare trimitere Nearby: $e";
      notifyListeners();
      return false;
    }
  }

  Future<bool> sendTextToThread(ChatThread thread, String text) async {
    if (!thread.isGroup) {
      final nodeId = thread.deviceId;
      if (nodeId == null) return false;
      return sendTextToDevice(nodeId, text);
    }

    final alias = _prefs.getString('alias') ?? "MeshChat";
    final payload = jsonEncode({
      "scope": "group",
      "groupId": thread.id,
      "senderNodeId": _localNodeId,
      "senderName": alias,
      "text": text,
    });

    var sentAny = false;

    for (final nodeId in thread.participantNodeIds) {
      final endpointId = _connectedEndpointByNodeId[nodeId];
      if (endpointId == null) continue;

      await Nearby().sendBytesPayload(
        endpointId,
        Uint8List.fromList(utf8.encode("__CHAT__:$payload")),
      );
      sentAny = true;
    }

    if (!sentAny) {
      _status = "No group members are connected.";
      notifyListeners();
    }
    return sentAny;
  }

  Future<String?> sendFileToDevice(String nodeId) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: false,
    );

    if (result == null || result.files.isEmpty) return null;

    final picked = result.files.single;
    final path = picked.path;

    if (path == null) {
      _status = "Could not access the file path.";
      notifyListeners();
      return null;
    }

    return sendPathPayloadToDevice(
      nodeId: nodeId,
      path: path,
      fileName: picked.name,
      size: picked.size,
      kind: "file",
    );
  }

  Future<String?> sendPathPayloadToDevice({
    required String nodeId,
    required String path,
    required String fileName,
    required int size,
    String kind = "file",
    String? groupId,
  }) async {
    final endpointId = _connectedEndpointByNodeId[nodeId];
    if (endpointId == null) {
      _status = "Device-ul nu este conectat.";
      notifyListeners();
      return null;
    }

    final sourceFile = File(path);
    if (!await sourceFile.exists()) {
      _status = "Fișierul nu există local.";
      notifyListeners();
      return null;
    }

    try {
      final payloadId = await Nearby().sendFilePayload(endpointId, path);
      final alias = _prefs.getString('alias') ?? "MeshChat";

      final metadata = {
        "payloadId": payloadId,
        "fileName": fileName,
        "size": size,
        "kind": kind,
        "groupId": groupId,
        "senderNodeId": _localNodeId,
        "senderName": alias,
      };

      await Nearby().sendBytesPayload(
        endpointId,
        Uint8List.fromList(utf8.encode("__FILE__:${jsonEncode(metadata)}")),
      );

      return path;
    } catch (e) {
      _status = kind == "voice"
          ? "Error sending voice message: $e"
          : "Error sending file: $e";
      notifyListeners();
      return null;
    }
  }

  Future<String?> sendPathPayloadToThread({
    required ChatThread thread,
    required String path,
    required String fileName,
    required int size,
    String kind = "file",
  }) async {
    if (!thread.isGroup) {
      final nodeId = thread.deviceId;
      if (nodeId == null) return null;
      return sendPathPayloadToDevice(
        nodeId: nodeId,
        path: path,
        fileName: fileName,
        size: size,
        kind: kind,
      );
    }

    var sentAny = false;
    for (final nodeId in thread.participantNodeIds) {
      final result = await sendPathPayloadToDevice(
        nodeId: nodeId,
        path: path,
        fileName: fileName,
        size: size,
        kind: kind,
        groupId: thread.id,
      );
      if (result != null) sentAny = true;
    }

    return sentAny ? path : null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      start();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _incomingController.close();
    _connectionRequestController.close();
    _groupInviteController.close();
    Nearby().stopAdvertising();
    Nearby().stopDiscovery();
    super.dispose();
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

// --- NAVIGARE + LISTENER GLOBAL ---
class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> with WidgetsBindingObserver {
  int _idx = 1;
  final PageController _pageController = PageController(initialPage: 1);

  StreamSubscription<NearbyIncomingMessage>? _incomingSub;
  StreamSubscription<NearbyConnectionRequest>? _connectionRequestSub;
  StreamSubscription<NearbyGroupInvite>? _groupInviteSub;
  bool _isAppInForeground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final nearby = Provider.of<NearbyProvider>(context, listen: false);

      _connectionRequestSub = nearby.connectionRequests.listen((request) {
        _showConnectionRequestDialog(request);
      });

      _incomingSub = nearby.incomingMessages.listen((incoming) {
        _saveIncomingMessageDirectly(incoming);
      });

      _groupInviteSub = nearby.groupInvites.listen((invite) {
        _showGroupInviteDialog(invite);
      });
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _incomingSub?.cancel();
    _connectionRequestSub?.cancel();
    _groupInviteSub?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isAppInForeground = state == AppLifecycleState.resumed;
  }

  void _goToPage(int i) {
    _pageController.animateToPage(
      i,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  Future<void> _showConnectionRequestDialog(
    NearbyConnectionRequest request,
  ) async {
    if (!mounted) return;

    final nearby = Provider.of<NearbyProvider>(context, listen: false);
    final settings = Provider.of<SettingsProvider>(context, listen: false);

    final isKnownGroupPeer = settings.threads.any(
      (t) => t.isGroup && t.participantNodeIds.contains(request.nodeId),
    );

    if (!request.isGroupInvite && isKnownGroupPeer) {
      await nearby.acceptConnection(request.endpointId);
      return;
    }

    final accept = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text(
            request.isGroupInvite
                ? "Group Invite"
                : "Nearby Connection Request",
          ),
          content: Text(
            request.isGroupInvite
                ? "${request.displayName} invites you to the group «${request.groupTitle ?? "MeshChat Group"}»."
                : "${request.displayName} wants to connect to you.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text("Reject"),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text("Accept"),
            ),
          ],
        );
      },
    );

    if (accept == true) {
      await nearby.acceptConnection(request.endpointId);
      if (!mounted) return;

      if (request.isGroupInvite && request.groupId != null) {
        settings.createGroupThread(
          title: request.groupTitle ?? "MeshChat Group",
          groupId: request.groupId,
          participantNodeIds: request.participantNodeIds,
          participantNames: request.participantNames,
        );
      } else {
        settings.getOrCreateThreadForDevice(
          deviceId: request.nodeId,
          title: request.displayName,
        );
      }
    } else {
      await nearby.rejectConnection(request.endpointId);
    }
  }

  Future<void> _showGroupInviteDialog(NearbyGroupInvite invite) async {
    if (!mounted) return;

    final settings = Provider.of<SettingsProvider>(context, listen: false);
    if (settings.threadById(invite.groupId) != null) return;

    final accept = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text("Group Invite"),
          content: Text(
            "${invite.inviterName} invites you to the group «${invite.groupTitle}».",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text("Refuză"),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text("Acceptă"),
            ),
          ],
        );
      },
    );

    if (accept == true && mounted) {
      settings.createGroupThread(
        title: invite.groupTitle,
        groupId: invite.groupId,
        participantNodeIds: invite.participantNodeIds,
        participantNames: invite.participantNames,
      );

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Te-ai alăturat grupului ${invite.groupTitle}."),
        ),
      );
    }
  }

  void _saveIncomingMessageDirectly(NearbyIncomingMessage incoming) {
    if (!mounted) return;

    final settings = Provider.of<SettingsProvider>(context, listen: false);

    final msg = ChatMessage(
      id: const Uuid().v4(),
      text: incoming.text,
      isMine: false,
      timestamp: DateTime.now(),
      type: incoming.type == NearbyIncomingType.voice
          ? "voice"
          : incoming.type == NearbyIncomingType.file
          ? "file"
          : "text",
      fileName: incoming.fileName,
      filePath: incoming.filePath,
      senderNodeId: incoming.senderNodeId ?? incoming.nodeId,
      senderName: incoming.senderName ?? incoming.displayName,
    );

    if (incoming.groupId != null) {
      final existing = settings.threadById(incoming.groupId!);
      final thread =
          existing ??
          settings.createGroupThread(
            title: "Grup MeshChat",
            groupId: incoming.groupId!,
            participantNodeIds: [incoming.nodeId],
            participantNames: {incoming.nodeId: incoming.displayName},
          );
      settings.addMessageToThreadId(thread.id, msg);
    } else {
      settings.addIncomingMessage(
        deviceId: incoming.nodeId,
        title: incoming.displayName,
        message: msg,
      );
    }

    final notificationBody = incoming.type == NearbyIncomingType.voice
        ? "Mesaj vocal nou"
        : incoming.type == NearbyIncomingType.file
        ? "Fișier primit: ${incoming.fileName ?? "fișier"}"
        : incoming.text;

    if (!_isAppInForeground && settings.notificationsEnabled) {
      AppNotifications.showMessage(
        title: incoming.groupId != null
            ? "${incoming.senderName ?? incoming.displayName} în grup"
            : incoming.displayName,
        body: notificationBody,
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          incoming.type == NearbyIncomingType.voice
              ? "Mesaj vocal nou de la ${incoming.senderName ?? incoming.displayName}"
              : incoming.type == NearbyIncomingType.file
              ? "Fișier primit de la ${incoming.senderName ?? incoming.displayName}: ${incoming.fileName ?? "fișier"}"
              : "Mesaj nou de la ${incoming.senderName ?? incoming.displayName}",
        ),
      ),
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
    final nearby = Provider.of<NearbyProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('MeshChat'),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text(
                '• ${nearby.discoveredDevices.length} online',
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
                            "No chats available.This app is in development,please report all the bugs via my github and enjoy!",
                            textAlign: TextAlign.center,
                          ),
                        )
                      : ListView.builder(
                          itemCount: settings.threads.length,
                          itemBuilder: (context, i) {
                            final t = settings.threads[i];
                            final online = t.isGroup
                                ? t.participantNodeIds.any(
                                    nearby.isDeviceOnline,
                                  )
                                : nearby.isDeviceOnline(t.deviceId);
                            final connected = t.isGroup
                                ? nearby.activeCountForThread(t) > 0
                                : nearby.isDeviceConnected(t.deviceId);

                            return ListTile(
                              leading: Stack(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: settings.accentColor,
                                    child: Icon(
                                      t.isGroup ? Icons.group : Icons.person,
                                      color: Colors.white,
                                    ),
                                  ),
                                  Positioned(
                                    right: 0,
                                    bottom: 0,
                                    child: Container(
                                      width: 12,
                                      height: 12,
                                      decoration: BoxDecoration(
                                        color: connected
                                            ? Colors.green
                                            : online
                                            ? Colors.orange
                                            : Colors.grey,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: Theme.of(
                                            context,
                                          ).scaffoldBackgroundColor,
                                          width: 2,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              title: Text(t.title),
                              subtitle: Text(
                                t.messages.isNotEmpty
                                    ? t.messages.last.text
                                    : t.isGroup
                                    ? "Group"
                                    : online
                                    ? "Online"
                                    : "Offline",
                                maxLines: 1,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    t.isGroup
                                        ? "${nearby.activeCountForThread(t)} active"
                                        : connected
                                        ? "Connected"
                                        : online
                                        ? "Online"
                                        : "Offline",
                                    style: TextStyle(
                                      color: connected
                                          ? Colors.green
                                          : online
                                          ? Colors.orange
                                          : Colors.grey,
                                      fontSize: 12,
                                    ),
                                  ),
                                  PopupMenuButton<String>(
                                    onSelected: (value) {
                                      if (value == "delete") {
                                        settings.deleteThread(t.id);
                                      }
                                    },
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(
                                        value: "delete",
                                        child: Text("Delete conversation"),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      ModernChatRoom(threadId: t.id),
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
class NearbyScannerPage extends StatelessWidget {
  const NearbyScannerPage({super.key});

  Future<void> _showCreateGroupDialog(BuildContext context) async {
    final nearby = Provider.of<NearbyProvider>(context, listen: false);
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final devices = nearby.onlineGroupCandidates();
    final selected = <String>{};
    final titleController = TextEditingController(text: "MeshChat Group");

    final create = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text("Create Group"),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(
                        labelText: "Group Name",
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Flexible(
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: devices.length,
                        itemBuilder: (_, i) {
                          final d = devices[i];
                          final connected = nearby.isDeviceConnected(d.nodeId);
                          return CheckboxListTile(
                            value: selected.contains(d.nodeId),
                            onChanged: (v) {
                              setDialogState(() {
                                if (v == true) {
                                  selected.add(d.nodeId);
                                } else {
                                  selected.remove(d.nodeId);
                                }
                              });
                            },
                            title: Text(d.displayName),
                            subtitle: Text(
                              connected
                                  ? "Connected"
                                  : "Online - requires connection",
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text("Cancel"),
                ),
                FilledButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () => Navigator.pop(dialogContext, true),
                  child: const Text("Create"),
                ),
              ],
            );
          },
        );
      },
    );

    if (create == true) {
      final names = <String, String>{};
      for (final d in devices.where((d) => selected.contains(d.nodeId))) {
        names[d.nodeId] = d.displayName;
      }

      final thread = settings.createGroupThread(
        title: titleController.text,
        participantNodeIds: selected.toList(),
        participantNames: names,
      );

      await nearby.sendGroupInvite(
        groupThread: thread,
        targetNodeIds: selected.toList(),
      );

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Invites sent for ${thread.title}.")),
        );
      }
    }

    titleController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nearby = Provider.of<NearbyProvider>(context);
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final entries = nearby.discoveredDevices;

    return Scaffold(
      appBar: AppBar(
        title: const Text("Nearby Scan"),
        actions: [
          IconButton(
            onPressed: nearby.restartNearby,
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
                  nearby.isAdvertising && nearby.isDiscovering
                      ? Icons.wifi_tethering
                      : Icons.wifi_tethering_off,
                  color: nearby.isAdvertising && nearby.isDiscovering
                      ? Colors.green
                      : Colors.orange,
                ),
                title: Text("My name: ${settings.alias}"),
                subtitle: Text(
                  "${nearby.status}\nID permanent: ${nearby.localNodeId}",
                ),
                isThreeLine: true,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    onPressed: nearby.startAdvertising,
                    child: Text(
                      nearby.isAdvertising
                          ? "Advertising ON"
                          : "Start Advertising",
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: nearby.startDiscovery,
                    child: Text(
                      nearby.isDiscovering ? "Discovery ON" : "Start Discovery",
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: entries.isEmpty
                    ? null
                    : () => _showCreateGroupDialog(context),
                icon: const Icon(Icons.group_add),
                label: const Text("Create Group"),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: entries.isEmpty
                  ? const Center(
                      child: Text(
                        "No Nearby devices found yet.\nRun the app on two real Android phones.",
                        textAlign: TextAlign.center,
                      ),
                    )
                  : ListView.builder(
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final device = entries[index];
                        final isConnected = nearby.isDeviceConnected(
                          device.nodeId,
                        );

                        return Card(
                          child: ListTile(
                            leading: Icon(
                              isConnected
                                  ? Icons.check_circle
                                  : Icons.phone_android,
                              color: isConnected ? Colors.green : null,
                            ),
                            title: Text(device.displayName),
                            subtitle: Text("Node ID: ${device.nodeId}"),
                            trailing: ElevatedButton(
                              onPressed: isConnected
                                  ? null
                                  : () async {
                                      settings.getOrCreateThreadForDevice(
                                        deviceId: device.nodeId,
                                        title: device.displayName,
                                      );
                                      await nearby.connectToDevice(
                                        device.nodeId,
                                      );
                                    },
                              child: Text(
                                isConnected ? "Connected" : "Connect",
                              ),
                            ),
                            onTap: () {
                              final thread = settings
                                  .getOrCreateThreadForDevice(
                                    deviceId: device.nodeId,
                                    title: device.displayName,
                                  );

                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      ModernChatRoom(threadId: thread.id),
                                ),
                              );
                            },
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
  final String threadId;

  const ModernChatRoom({super.key, required this.threadId});

  @override
  State<ModernChatRoom> createState() => _ModernChatRoomState();
}

class _ModernChatRoomState extends State<ModernChatRoom> {
  final TextEditingController _msgController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final AudioRecorder _audioRecorder = AudioRecorder();

  bool _isRecordingVoice = false;
  String? _recordingPath;

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

  bool _isAudioFile(String? fileName) {
    if (fileName == null) return false;
    final lower = fileName.toLowerCase();

    return lower.endsWith(".m4a") ||
        lower.endsWith(".aac") ||
        lower.endsWith(".mp3") ||
        lower.endsWith(".wav") ||
        lower.endsWith(".ogg") ||
        lower.endsWith(".opus");
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
    final audioPreview = message.isVoice || _isAudioFile(fileName);

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
                audioPreview
                    ? Icons.mic
                    : videoPreview
                    ? Icons.videocam
                    : Icons.insert_drive_file,
                size: 46,
                color: message.isMine ? Colors.white : null,
              ),
            ),
          const SizedBox(height: 8),
          Text(
            message.isVoice ? "Mesaj vocal" : fileName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: message.isMine ? Colors.white : null,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: fileExists ? () => _openFile(message) : null,
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: Text(
                    message.isVoice || audioPreview ? "Play" : "Open",
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: fileExists ? () => _downloadFile(message) : null,
                  icon: const Icon(Icons.file_download_outlined, size: 18),
                  label: const Text("Save"),
                ),
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

  Future<void> _sendFile(ChatThread thread) async {
    final nearby = Provider.of<NearbyProvider>(context, listen: false);
    final settings = Provider.of<SettingsProvider>(context, listen: false);

    if (thread.isGroup && nearby.activeCountForThread(thread) == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Nu există membri conectați în grup.")),
      );
      return;
    }

    if (!thread.isGroup && !nearby.isDeviceConnected(thread.deviceId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Conectează-te la device înainte să trimiți fișiere."),
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
    if (path == null) return;

    final sentPath = await nearby.sendPathPayloadToThread(
      thread: thread,
      path: path,
      fileName: picked.name,
      size: picked.size,
      kind: "file",
    );

    if (sentPath == null) {
      if (nearby.status.isNotEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(nearby.status)));
      }
      return;
    }

    settings.addMessageToThreadId(
      thread.id,
      ChatMessage(
        id: const Uuid().v4(),
        text: "📎 Fișier trimis: ${picked.name}",
        isMine: true,
        timestamp: DateTime.now(),
        type: "file",
        fileName: picked.name,
        filePath: sentPath,
      ),
    );

    _scrollToBottom();
  }

  Future<void> _toggleVoiceRecording(ChatThread thread) async {
    if (_isRecordingVoice) {
      await _stopAndSendVoice(thread);
    } else {
      await _startVoiceRecording(thread);
    }
  }

  Future<void> _startVoiceRecording(ChatThread thread) async {
    final nearby = Provider.of<NearbyProvider>(context, listen: false);

    if (thread.isGroup && nearby.activeCountForThread(thread) == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Nu există membri conectați în grup.")),
      );
      return;
    }

    if (!thread.isGroup && !nearby.isDeviceConnected(thread.deviceId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Connect to the device before sending voice messages."),
        ),
      );
      return;
    }

    final micOk = await requestMicrophonePermission();
    if (!micOk) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "Microphone permission is required for voice messages.",
          ),
        ),
      );
      return;
    }

    final hasRecorderPermission = await _audioRecorder.hasPermission();
    if (!hasRecorderPermission) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("The app does not have access to the microphone."),
        ),
      );
      return;
    }

    final dir = await getTemporaryDirectory();
    final fileName = "voice_${DateTime.now().millisecondsSinceEpoch}.m4a";
    final path = "${dir.path}/$fileName";

    await _audioRecorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: path,
    );

    setState(() {
      _isRecordingVoice = true;
      _recordingPath = path;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Recording started. Tap the microphone again to send."),
      ),
    );
  }

  Future<void> _stopAndSendVoice(ChatThread thread) async {
    final nearby = Provider.of<NearbyProvider>(context, listen: false);
    final settings = Provider.of<SettingsProvider>(context, listen: false);

    final stoppedPath = await _audioRecorder.stop();

    setState(() {
      _isRecordingVoice = false;
      _recordingPath = null;
    });

    final path = stoppedPath;
    if (path == null || path.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Înregistrarea nu a fost salvată.")),
      );
      return;
    }

    final file = File(path);
    if (!await file.exists()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Fișierul audio nu există local.")),
      );
      return;
    }

    final fileName = path.split(Platform.pathSeparator).last;
    final sentPath = await nearby.sendPathPayloadToThread(
      thread: thread,
      path: path,
      fileName: fileName,
      size: await file.length(),
      kind: "voice",
    );

    if (sentPath == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(nearby.status)));
      return;
    }

    settings.addMessageToThreadId(
      thread.id,
      ChatMessage(
        id: const Uuid().v4(),
        text: "🎤 Mesaj vocal",
        isMine: true,
        timestamp: DateTime.now(),
        type: "voice",
        fileName: fileName,
        filePath: sentPath,
      ),
    );

    _scrollToBottom();
  }

  Future<void> _send(ChatThread thread) async {
    if (_msgController.text.trim().isEmpty) return;

    final text = _msgController.text.trim();
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final nearby = Provider.of<NearbyProvider>(context, listen: false);

    settings.addMessageToThreadId(
      thread.id,
      ChatMessage(
        id: const Uuid().v4(),
        text: text,
        isMine: true,
        timestamp: DateTime.now(),
      ),
    );

    _msgController.clear();
    _scrollToBottom();

    final sent = await nearby.sendTextToThread(thread, text);
    if (!sent && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(nearby.status)));
    }
  }

  void _showActiveMembers(ChatThread thread, NearbyProvider nearby) {
    final names = nearby.activeNamesForThread(thread);

    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text("Membri activi (${names.length})"),
        content: names.isEmpty
            ? const Text("Niciun membru conectat momentan.")
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: names
                    .map(
                      (n) => ListTile(
                        leading: const Icon(Icons.person),
                        title: Text(n),
                      ),
                    )
                    .toList(),
              ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("OK"),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddMembersDialog(
    ChatThread thread,
    NearbyProvider nearby,
    SettingsProvider settings,
  ) async {
    final candidates = nearby
        .onlineGroupCandidates()
        .where((d) => !thread.participantNodeIds.contains(d.nodeId))
        .toList();

    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("No new online devices to add.")),
      );
      return;
    }

    final selected = <String>{};

    final add = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text("Add members"),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: candidates.length,
                  itemBuilder: (_, i) {
                    final d = candidates[i];
                    return CheckboxListTile(
                      value: selected.contains(d.nodeId),
                      onChanged: (v) {
                        setDialogState(() {
                          if (v == true) {
                            selected.add(d.nodeId);
                          } else {
                            selected.remove(d.nodeId);
                          }
                        });
                      },
                      title: Text(d.displayName),
                      subtitle: Text(
                        nearby.isDeviceConnected(d.nodeId)
                            ? "Connected"
                            : "Online - requires connection",
                      ),
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text("Cancel"),
                ),
                FilledButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () => Navigator.pop(dialogContext, true),
                  child: const Text("Add"),
                ),
              ],
            );
          },
        );
      },
    );

    if (add == true) {
      for (final d in candidates.where((d) => selected.contains(d.nodeId))) {
        if (!thread.participantNodeIds.contains(d.nodeId)) {
          thread.participantNodeIds.add(d.nodeId);
        }
        thread.participantNames[d.nodeId] = d.displayName;
      }

      settings.saveThread(thread);

      await nearby.sendGroupInvite(
        groupThread: thread,
        targetNodeIds: selected.toList(),
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Invites sent to ${selected.length} members.")),
      );
    }
  }

  @override
  void dispose() {
    _audioRecorder.dispose();
    _msgController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = Provider.of<SettingsProvider>(context);
    final nearby = Provider.of<NearbyProvider>(context);
    final thread = settings.threadById(widget.threadId);

    if (thread == null) {
      return Scaffold(
        appBar: AppBar(title: const Text("Chat")),
        body: const Center(child: Text("The conversation no longer exists.")),
      );
    }

    final nodeId = thread.deviceId;
    final online = thread.isGroup
        ? thread.participantNodeIds.any(nearby.isDeviceOnline)
        : nearby.isDeviceOnline(nodeId);
    final connected = thread.isGroup
        ? nearby.activeCountForThread(thread) > 0
        : nearby.isDeviceConnected(nodeId);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(thread.title),
            Text(
              thread.isGroup
                  ? "${nearby.activeCountForThread(thread)} active people"
                  : connected
                  ? "Connected Nearby"
                  : online
                  ? "Online, not connected"
                  : "Offline",
              style: TextStyle(
                fontSize: 12,
                color: connected
                    ? Colors.green
                    : online
                    ? Colors.orange
                    : null,
              ),
            ),
          ],
        ),
        actions: [
          if (thread.isGroup)
            IconButton(
              tooltip: "Add members",
              onPressed: () => _showAddMembersDialog(thread, nearby, settings),
              icon: const Icon(Icons.person_add),
            ),
          if (thread.isGroup)
            TextButton.icon(
              onPressed: () => nearby.connectThreadDevices(thread),
              icon: const Icon(Icons.link),
              label: const Text("Connect"),
            ),
          if (thread.isGroup)
            TextButton.icon(
              onPressed: () => _showActiveMembers(thread, nearby),
              icon: const Icon(Icons.group),
              label: Text("${nearby.activeCountForThread(thread)} active"),
            ),
          if (!thread.isGroup && nodeId != null)
            TextButton.icon(
              onPressed: connected
                  ? () => nearby.disconnectDevice(nodeId)
                  : online
                  ? () => nearby.connectToDevice(nodeId)
                  : null,
              icon: Icon(connected ? Icons.link_off : Icons.link),
              label: Text(connected ? "Disconnect" : "Connect"),
            ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            color: connected
                ? Colors.green.withOpacity(0.15)
                : online
                ? Colors.orange.withOpacity(0.15)
                : Colors.grey.withOpacity(0.15),
            child: Text(
              thread.isGroup
                  ? "Group: ${nearby.activeCountForThread(thread)} connected members. Press Connect to reconnect online members."
                  : connected
                  ? "Nearby ready: messages and files are sent to the connected device."
                  : online
                  ? "Device online. Press Connect to resume the conversation."
                  : "Device offline or not detected at the moment.",
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          Expanded(
            child: thread.messages.isEmpty
                ? const Center(child: Text("No messages yet."))
                : ListView.builder(
                    controller: _scrollController,
                    itemCount: thread.messages.length,
                    itemBuilder: (context, i) {
                      final message = thread.messages[i];

                      return Align(
                        alignment: message.isMine
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: (message.isFile || message.isVoice)
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
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (thread.isGroup &&
                                        !message.isMine &&
                                        message.senderName != null)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          bottom: 4,
                                        ),
                                        child: Text(
                                          message.senderName!,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: message.isMine
                                                ? Colors.white70
                                                : Theme.of(
                                                    context,
                                                  ).colorScheme.primary,
                                          ),
                                        ),
                                      ),
                                    Text(
                                      message.text,
                                      style: TextStyle(
                                        color: message.isMine
                                            ? Colors.white
                                            : null,
                                      ),
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
                      onSubmitted: (_) => _send(thread),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: connected ? () => _sendFile(thread) : null,
                    icon: const Icon(Icons.attach_file),
                  ),
                  IconButton.filledTonal(
                    onPressed: connected
                        ? () => _toggleVoiceRecording(thread)
                        : null,
                    icon: Icon(_isRecordingVoice ? Icons.stop : Icons.mic),
                  ),
                  IconButton.filled(
                    onPressed: () => _send(thread),
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
    final nearby = Provider.of<NearbyProvider>(context, listen: false);

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
              "${settings.alias} • ID permanent: ${nearby.localNodeId}",
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
                      hintText: "Ex: User, Telefonul meu",
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (value) async {
                      settings.updateAlias(value);
                      await nearby.restartNearby();

                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("Alias saved and Nearby restarted."),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () async {
                        settings.updateAlias(_aliasController.text);
                        await nearby.restartNearby();

                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text("Alias saved and Nearby restarted."),
                          ),
                        );
                      },
                      child: const Text("Save Alias"),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    "The name remains saved. The permanent ID does not change on restart, so conversations can be resumed when the device comes online.",
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
          SwitchListTile(
            title: const Text("Notifications"),
            subtitle: const Text(
              "You will only receive notifications when the app is not open.",
            ),
            value: settings.notificationsEnabled,
            onChanged: (v) => settings.toggleNotifications(v),
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
