// Stable rebuild note:
// This version intentionally keeps Nearby connections peer-to-peer only.
// Groups are only a routing layer over already connected P2P endpoints.
// To create or add members to a group, devices must already be connected.
// This avoids the unstable special group-handshake logic.

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

const String kNearbyServiceId = 'com.meshup.chat';
const String kEndpointSeparator = '::';

const String kPayloadGroupInvite = '__GROUP_INVITE__:';
const String kPayloadGroupMessage = '__GROUP_MESSAGE__:';
const String kPayloadFile = '__FILE__:';

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

// -----------------------------------------------------------------------------
// NOTIFICATIONS
// -----------------------------------------------------------------------------
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

void showTopInAppNotification(
  BuildContext context, {
  required String message,
  required Color accentColor,
  IconData icon = Icons.notifications_none,
  Duration duration = const Duration(seconds: 3),
}) {
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return;

  late OverlayEntry entry;
  var removed = false;

  void remove() {
    if (removed) return;
    removed = true;
    entry.remove();
  }

  entry = OverlayEntry(
    builder: (context) {
      final theme = Theme.of(context);
      final isDark = theme.brightness == Brightness.dark;
      final backgroundColor = isDark
          ? Color.alphaBlend(
              accentColor.withOpacity(0.32),
              const Color(0xFF171A21),
            )
          : Color.alphaBlend(accentColor.withOpacity(0.14), Colors.white);
      final borderColor = accentColor.withOpacity(isDark ? 0.55 : 0.35);
      final iconBackgroundColor = accentColor.withOpacity(isDark ? 0.28 : 0.16);
      final textColor = isDark ? Colors.white : const Color(0xFF111827);

      return Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: remove,
                borderRadius: BorderRadius.circular(18),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: backgroundColor,
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: borderColor),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(isDark ? 0.35 : 0.16),
                        blurRadius: 18,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: iconBackgroundColor,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(icon, color: accentColor, size: 20),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          message,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: textColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        Icons.close,
                        size: 18,
                        color: textColor.withOpacity(0.75),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  overlay.insert(entry);
  Future.delayed(duration, remove);
}

// -----------------------------------------------------------------------------
// PERMISSIONS
// -----------------------------------------------------------------------------
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

  debugPrint('Nearby permissions:');
  debugPrint('LOCATION: $locationOk');
  debugPrint('BT SCAN: $scanOk');
  debugPrint('BT ADVERTISE: $advertiseOk');
  debugPrint('BT CONNECT: $connectOk');
  debugPrint('NEARBY WIFI: $nearbyWifiOk');

  return locationOk && scanOk && advertiseOk && connectOk && nearbyWifiOk;
}

Future<bool> requestMicrophonePermission() async {
  if (!Platform.isAndroid && !Platform.isIOS) return true;
  final status = await Permission.microphone.request();
  return status.isGranted;
}

// -----------------------------------------------------------------------------
// MODELS
// -----------------------------------------------------------------------------
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
    this.type = 'text',
    this.fileName,
    this.filePath,
    this.senderNodeId,
    this.senderName,
  });

  bool get isFile => type == 'file';
  bool get isVoice => type == 'voice';

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
    type: json['type'] ?? 'text',
    fileName: json['fileName'],
    filePath: json['filePath'],
    senderNodeId: json['senderNodeId'],
    senderName: json['senderName'],
  );
}

class ChatThread {
  final String id;
  String title;

  // For direct chats only.
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

  NearbyConnectionRequest({
    required this.endpointId,
    required this.nodeId,
    required this.displayName,
  });
}

enum NearbyIncomingType { text, file, voice }

class NearbyIncomingMessage {
  final String endpointId;
  final String nodeId;
  final String displayName;
  final String text;
  final NearbyIncomingType type;
  final String? filePath;
  final String? fileName;
  final String? groupId;
  final String? groupTitle;
  final List<String>? groupParticipantNodeIds;
  final Map<String, String>? groupParticipantNames;
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
    this.groupTitle,
    this.groupParticipantNodeIds,
    this.groupParticipantNames,
    this.senderNodeId,
    this.senderName,
  });
}

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

class ParsedEndpointName {
  final String displayName;
  final String nodeId;

  ParsedEndpointName({required this.displayName, required this.nodeId});
}

ParsedEndpointName parseEndpointName(String raw) {
  if (!raw.contains(kEndpointSeparator)) {
    return ParsedEndpointName(displayName: raw, nodeId: raw);
  }

  final parts = raw.split(kEndpointSeparator);
  final nodeId = parts.removeLast();
  final displayName = parts.join(kEndpointSeparator).trim();

  return ParsedEndpointName(
    displayName: displayName.isEmpty ? 'MeshChat' : displayName,
    nodeId: nodeId,
  );
}

// -----------------------------------------------------------------------------
// SETTINGS PROVIDER
// -----------------------------------------------------------------------------
class SettingsProvider extends ChangeNotifier {
  final SharedPreferences _prefs;

  bool _isDarkMode = true;
  bool _saveHistory = true;
  bool _notificationsEnabled = true;
  bool _inAppNotificationsEnabled = true;
  Color _accentColor = const Color(0xFF0052D4);
  String _alias = 'MeshChat';
  List<ChatThread> _threads = [];

  SettingsProvider(this._prefs) {
    _isDarkMode = _prefs.getBool('dark_mode') ?? true;
    _saveHistory = _prefs.getBool('save_history') ?? true;
    _notificationsEnabled = _prefs.getBool('notifications_enabled') ?? true;
    _inAppNotificationsEnabled =
        _prefs.getBool('in_app_notifications_enabled') ?? true;
    _accentColor = Color(_prefs.getInt('accent_color') ?? 0xFF0052D4);
    _alias = _prefs.getString('alias') ?? 'MeshChat';
    _loadThreads();
  }

  bool get isDarkMode => _isDarkMode;
  bool get saveHistory => _saveHistory;
  bool get notificationsEnabled => _notificationsEnabled;
  bool get inAppNotificationsEnabled => _inAppNotificationsEnabled;
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

  void toggleInAppNotifications(bool val) {
    _inAppNotificationsEnabled = val;
    _prefs.setBool('in_app_notifications_enabled', val);
    notifyListeners();
  }

  void updateAccent(Color c) {
    _accentColor = c;
    _prefs.setInt('accent_color', c.value);
    notifyListeners();
  }

  void _loadThreads() {
    final raw = _prefs.getString('chat_threads');
    if (raw == null) return;

    try {
      final List decoded = jsonDecode(raw);
      _threads = decoded.map((e) => ChatThread.fromJson(e)).toList();
    } catch (e) {
      debugPrint('Error loading threads: $e');
      _threads = [];
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
      if (title.trim().isNotEmpty && existing.title != title.trim()) {
        existing.title = title.trim();
        existing.participantNames[deviceId] = title.trim();
        saveThread(existing);
      }
      return existing;
    }

    final thread = ChatThread(
      id: const Uuid().v4(),
      title: title.trim().isEmpty ? 'Device' : title.trim(),
      deviceId: deviceId,
      isGroup: false,
      participantNodeIds: [deviceId],
      participantNames: {
        deviceId: title.trim().isEmpty ? 'Device' : title.trim(),
      },
      messages: [],
    );

    _threads.insert(0, thread);
    _persistThreads();
    notifyListeners();
    return thread;
  }

  ChatThread createOrUpdateGroupThread({
    required String groupId,
    required String title,
    required List<String> participantNodeIds,
    required Map<String, String> participantNames,
  }) {
    final existing = threadById(groupId);

    if (existing != null) {
      for (final id in participantNodeIds) {
        if (!existing.participantNodeIds.contains(id)) {
          existing.participantNodeIds.add(id);
        }
      }
      existing.participantNames.addAll(participantNames);
      if (title.trim().isNotEmpty) existing.title = title.trim();
      saveThread(existing);
      return existing;
    }

    final thread = ChatThread(
      id: groupId,
      title: title.trim().isEmpty ? 'MeshChat Group' : title.trim(),
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

  ChatThread createGroupThread({
    required String title,
    required List<String> participantNodeIds,
    required Map<String, String> participantNames,
  }) {
    return createOrUpdateGroupThread(
      groupId: const Uuid().v4(),
      title: title,
      participantNodeIds: participantNodeIds,
      participantNames: participantNames,
    );
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

  ChatThread addIncomingDirectMessage({
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

// -----------------------------------------------------------------------------
// NEARBY PROVIDER
// -----------------------------------------------------------------------------
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
  String _status = 'Nearby is not running yet.';

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

  List<NearbyDevice> get connectedDevices {
    return _connectedEndpointByNodeId.keys
        .map(deviceByNodeId)
        .whereType<NearbyDevice>()
        .toList();
  }

  Stream<NearbyIncomingMessage> get incomingMessages =>
      _incomingController.stream;
  Stream<NearbyConnectionRequest> get connectionRequests =>
      _connectionRequestController.stream;
  Stream<NearbyGroupInvite> get groupInvites => _groupInviteController.stream;

  String advertisingName(String alias) =>
      '$alias$kEndpointSeparator$_localNodeId';

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

  NearbyDevice? deviceByEndpointId(String endpointId) =>
      _devicesByEndpoint[endpointId];

  int connectedOtherCountForGroup(ChatThread thread) {
    if (!thread.isGroup) return 0;
    return thread.participantNodeIds
        .where((id) => id != _localNodeId)
        .where(isDeviceConnected)
        .length;
  }

  int activeCountForThread(ChatThread thread) {
    if (!thread.isGroup) return isDeviceConnected(thread.deviceId) ? 1 : 0;
    final self = thread.participantNodeIds.contains(_localNodeId) ? 1 : 0;
    return self + connectedOtherCountForGroup(thread);
  }

  List<String> activeNamesForThread(ChatThread thread) {
    if (!thread.isGroup) {
      if (!isDeviceConnected(thread.deviceId)) return [];
      return [thread.title];
    }

    final names = <String>[];

    if (thread.participantNodeIds.contains(_localNodeId)) {
      names.add('${_prefs.getString('alias') ?? 'Me'} (me)');
    }

    for (final id in thread.participantNodeIds) {
      if (id == _localNodeId) continue;
      if (!isDeviceConnected(id)) continue;
      names.add(
        thread.participantNames[id] ?? deviceByNodeId(id)?.displayName ?? id,
      );
    }

    return names;
  }

  Future<void> start() async {
    if (_isStarting) return;
    _isStarting = true;

    final ok = await requestNearbyPermissions();
    if (!ok) {
      _status = 'Permissions denied. Enable Location / Nearby devices / Wi-Fi.';
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
      final alias = _prefs.getString('alias') ?? 'MeshChat';
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
          ? 'Advertising started as $alias.'
          : 'Advertising failed.';
      notifyListeners();
    } catch (e) {
      _isAdvertising = false;
      _status = 'Advertising error: $e';
      notifyListeners();
    }
  }

  Future<void> startDiscovery() async {
    try {
      final alias = _prefs.getString('alias') ?? 'MeshChat';
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

          _status = 'Found: ${parsed.displayName}';
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
      if (result) _status = 'Discovery started.';
      notifyListeners();
    } catch (e) {
      _isDiscovering = false;
      _status = 'Discovery error: $e';
      notifyListeners();
    }
  }

  void _onConnectionInitiated(
    String endpointId,
    ConnectionInfo connectionInfo,
  ) {
    final parsed = parseEndpointName(connectionInfo.endpointName);

    _devicesByEndpoint[endpointId] = NearbyDevice(
      endpointId: endpointId,
      nodeId: parsed.nodeId,
      displayName: parsed.displayName,
    );

    _status = 'Connection request from ${parsed.displayName}.';
    notifyListeners();

    _connectionRequestController.add(
      NearbyConnectionRequest(
        endpointId: endpointId,
        nodeId: parsed.nodeId,
        displayName: parsed.displayName,
      ),
    );
  }

  Future<void> acceptConnection(String endpointId) async {
    try {
      await Nearby().acceptConnection(
        endpointId,
        onPayLoadRecieved: _onPayloadReceived,
        onPayloadTransferUpdate: (endpointId, update) {
          debugPrint('Payload update from $endpointId: ${update.status}');
        },
      );

      final device = _devicesByEndpoint[endpointId];
      if (device != null) {
        _status = 'Connection accepted with ${device.displayName}.';
      }
      notifyListeners();
    } catch (e) {
      _status = 'Accept connection error: $e';
      notifyListeners();
    }
  }

  Future<void> rejectConnection(String endpointId) async {
    try {
      await Nearby().rejectConnection(endpointId);
      _status = 'Connection rejected.';
      notifyListeners();
    } catch (e) {
      _status = 'Reject connection error: $e';
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
      _status = 'Connected to $name.';
    } else {
      if (device != null) {
        _connectedEndpointByNodeId.remove(device.nodeId);
      }
      _status = 'Connection failed with $name: $status';
    }

    notifyListeners();
  }

  void _onDisconnected(String endpointId) {
    final device = _devicesByEndpoint[endpointId];
    if (device != null) {
      _connectedEndpointByNodeId.remove(device.nodeId);
      _status = 'Disconnected: ${device.displayName}';
    } else {
      _status = 'Disconnected: $endpointId';
    }
    notifyListeners();
  }

  Future<void> connectToDevice(String nodeId) async {
    final device = deviceByNodeId(nodeId);
    if (device == null) {
      _status = 'Device is not online or not discovered.';
      notifyListeners();
      return;
    }

    try {
      _status = 'Requesting connection with ${device.displayName}...';
      notifyListeners();

      await Nearby().requestConnection(
        advertisingName(_prefs.getString('alias') ?? 'MeshChat'),
        device.endpointId,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
    } catch (e) {
      _status = 'Connect error: $e';
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
    _status = 'Disconnected.';
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
      if (nodeId == _localNodeId) continue;
      if (!isDeviceConnected(nodeId) && isDeviceOnline(nodeId)) {
        await connectToDevice(nodeId);
        await Future.delayed(const Duration(milliseconds: 600));
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
    _status = 'Restarting Nearby...';
    notifyListeners();

    await Future.delayed(const Duration(milliseconds: 500));
    await start();
  }

  Future<void> sendGroupInvite({
    required ChatThread groupThread,
    required List<String> targetNodeIds,
  }) async {
    final alias = _prefs.getString('alias') ?? 'MeshChat';

    final payload = {
      'groupId': groupThread.id,
      'groupTitle': groupThread.title,
      'inviterNodeId': _localNodeId,
      'inviterName': alias,
      'participantNodeIds': groupThread.participantNodeIds,
      'participantNames': groupThread.participantNames,
    };

    for (final nodeId in targetNodeIds.toSet()) {
      if (nodeId == _localNodeId) continue;
      final endpointId = _connectedEndpointByNodeId[nodeId];
      if (endpointId == null) continue;

      await Nearby().sendBytesPayload(
        endpointId,
        Uint8List.fromList(
          utf8.encode('$kPayloadGroupInvite${jsonEncode(payload)}'),
        ),
      );
    }
  }

  void _onPayloadReceived(String endpointId, Payload payload) {
    final device = _devicesByEndpoint[endpointId];
    final nodeId = device?.nodeId ?? endpointId;
    final displayName = device?.displayName ?? endpointId;

    if (payload.type == PayloadType.BYTES) {
      final bytes = payload.bytes;
      if (bytes == null) return;

      final text = utf8.decode(bytes, allowMalformed: true);

      if (text.startsWith(kPayloadGroupInvite)) {
        final raw = text.replaceFirst(kPayloadGroupInvite, '');
        try {
          final data = jsonDecode(raw) as Map<String, dynamic>;
          _groupInviteController.add(
            NearbyGroupInvite(
              endpointId: endpointId,
              groupId: data['groupId'] as String,
              groupTitle: data['groupTitle'] as String,
              inviterNodeId: data['inviterNodeId'] as String,
              inviterName: data['inviterName'] as String,
              participantNodeIds:
                  ((data['participantNodeIds'] as List?) ?? const [])
                      .map((e) => e.toString())
                      .toList(),
              participantNames: Map<String, String>.from(
                data['participantNames'] ?? {},
              ),
            ),
          );
        } catch (e) {
          debugPrint('Group invite parse error: $e');
        }
        return;
      }

      if (text.startsWith(kPayloadGroupMessage)) {
        final raw = text.replaceFirst(kPayloadGroupMessage, '');
        try {
          final data = jsonDecode(raw) as Map<String, dynamic>;
          _incomingController.add(
            NearbyIncomingMessage(
              endpointId: endpointId,
              nodeId: data['senderNodeId'] as String? ?? nodeId,
              displayName: data['senderName'] as String? ?? displayName,
              text: data['text'] as String? ?? '',
              type: NearbyIncomingType.text,
              groupId: data['groupId'] as String?,
              groupTitle: data['groupTitle'] as String?,
              groupParticipantNodeIds:
                  ((data['participantNodeIds'] as List?) ?? const [])
                      .map((e) => e.toString())
                      .toList(),
              groupParticipantNames: Map<String, String>.from(
                data['participantNames'] ?? {},
              ),
              senderNodeId: data['senderNodeId'] as String? ?? nodeId,
              senderName: data['senderName'] as String? ?? displayName,
            ),
          );
        } catch (e) {
          debugPrint('Group message parse error: $e');
        }
        return;
      }

      if (text.startsWith(kPayloadFile)) {
        final raw = text.replaceFirst(kPayloadFile, '');
        try {
          final data = jsonDecode(raw) as Map<String, dynamic>;
          final payloadId = data['payloadId'] as int;
          final fileName = data['fileName'] as String;
          final kind = data['kind'] as String? ?? 'file';
          final groupId = data['groupId'] as String?;
          final senderNodeId = data['senderNodeId'] as String?;
          final senderName = data['senderName'] as String?;

          _pendingFileNames[payloadId] = fileName;
          _pendingFileKinds[payloadId] = kind;
          if (groupId != null) _pendingFileGroupIds[payloadId] = groupId;
          if (senderNodeId != null) {
            _pendingFileSenderNodeIds[payloadId] = senderNodeId;
          }
          if (senderName != null) {
            _pendingFileSenderNames[payloadId] = senderName;
          }

          _saveReceivedFileIfReady(
            payloadId: payloadId,
            endpointId: endpointId,
          );
        } catch (e) {
          debugPrint('File metadata parse error: $e');
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
      if (uri == null) return;
      _pendingFileUris[payload.id] = uri;
      _saveReceivedFileIfReady(payloadId: payload.id, endpointId: endpointId);
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
    if (dir == null) return;

    final safeName = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final destinationPath = '${dir.path}/$safeName';
    final copied = await Nearby().copyFileAndDeleteOriginal(
      fileUri,
      destinationPath,
    );

    final device = _devicesByEndpoint[endpointId];
    final nodeId =
        _pendingFileSenderNodeIds[payloadId] ?? device?.nodeId ?? endpointId;
    final displayName =
        _pendingFileSenderNames[payloadId] ?? device?.displayName ?? endpointId;
    final kind = _pendingFileKinds[payloadId] ?? 'file';
    final groupId = _pendingFileGroupIds[payloadId];

    if (copied) {
      _incomingController.add(
        NearbyIncomingMessage(
          endpointId: endpointId,
          nodeId: nodeId,
          displayName: displayName,
          text: kind == 'voice'
              ? '🎤 Voice message'
              : '📎 File received: $safeName',
          type: kind == 'voice'
              ? NearbyIncomingType.voice
              : NearbyIncomingType.file,
          filePath: destinationPath,
          fileName: safeName,
          groupId: groupId,
          senderNodeId: nodeId,
          senderName: displayName,
        ),
      );
    }

    _pendingFileNames.remove(payloadId);
    _pendingFileUris.remove(payloadId);
    _pendingFileKinds.remove(payloadId);
    _pendingFileGroupIds.remove(payloadId);
    _pendingFileSenderNodeIds.remove(payloadId);
    _pendingFileSenderNames.remove(payloadId);
  }

  Future<bool> sendTextToDevice(String nodeId, String text) async {
    final endpointId = _connectedEndpointByNodeId[nodeId];
    if (endpointId == null) {
      _status = 'Device is not connected.';
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
      _status = 'Send message error: $e';
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

    final alias = _prefs.getString('alias') ?? 'MeshChat';
    final payload = {
      'groupId': thread.id,
      'groupTitle': thread.title,
      'text': text,
      'senderNodeId': _localNodeId,
      'senderName': alias,
      'participantNodeIds': thread.participantNodeIds,
      'participantNames': thread.participantNames,
    };

    var sentAny = false;

    for (final nodeId in thread.participantNodeIds) {
      if (nodeId == _localNodeId) continue;
      final endpointId = _connectedEndpointByNodeId[nodeId];
      if (endpointId == null) continue;

      await Nearby().sendBytesPayload(
        endpointId,
        Uint8List.fromList(
          utf8.encode('$kPayloadGroupMessage${jsonEncode(payload)}'),
        ),
      );
      sentAny = true;
    }

    if (!sentAny) {
      _status = 'No connected group members.';
      notifyListeners();
    }

    return sentAny;
  }

  Future<String?> sendPathPayloadToDevice({
    required String nodeId,
    required String path,
    required String fileName,
    required int size,
    String kind = 'file',
    String? groupId,
  }) async {
    final endpointId = _connectedEndpointByNodeId[nodeId];
    if (endpointId == null) {
      _status = 'Device is not connected.';
      notifyListeners();
      return null;
    }

    final sourceFile = File(path);
    if (!await sourceFile.exists()) {
      _status = 'File does not exist locally.';
      notifyListeners();
      return null;
    }

    try {
      final payloadId = await Nearby().sendFilePayload(endpointId, path);
      final alias = _prefs.getString('alias') ?? 'MeshChat';

      final metadata = {
        'payloadId': payloadId,
        'fileName': fileName,
        'size': size,
        'kind': kind,
        'groupId': groupId,
        'senderNodeId': _localNodeId,
        'senderName': alias,
      };

      await Nearby().sendBytesPayload(
        endpointId,
        Uint8List.fromList(utf8.encode('$kPayloadFile${jsonEncode(metadata)}')),
      );

      return path;
    } catch (e) {
      _status = kind == 'voice'
          ? 'Voice send error: $e'
          : 'File send error: $e';
      notifyListeners();
      return null;
    }
  }

  Future<String?> sendPathPayloadToThread({
    required ChatThread thread,
    required String path,
    required String fileName,
    required int size,
    String kind = 'file',
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
      if (nodeId == _localNodeId) continue;
      if (!isDeviceConnected(nodeId)) continue;

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
    if (state == AppLifecycleState.resumed) start();
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

// -----------------------------------------------------------------------------
// APP
// -----------------------------------------------------------------------------
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

      _connectionRequestSub = nearby.connectionRequests.listen(
        _showConnectionRequestDialog,
      );
      _incomingSub = nearby.incomingMessages.listen(
        _saveIncomingMessageDirectly,
      );
      _groupInviteSub = nearby.groupInvites.listen(_showGroupInviteDialog);
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

    if (isKnownGroupPeer) {
      await nearby.acceptConnection(request.endpointId);
      return;
    }

    final accept = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Nearby Connection Request'),
        content: Text('${request.displayName} wants to connect to you.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Reject'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Accept'),
          ),
        ],
      ),
    );

    if (accept == true) {
      await nearby.acceptConnection(request.endpointId);
      if (!mounted) return;
      settings.getOrCreateThreadForDevice(
        deviceId: request.nodeId,
        title: request.displayName,
      );
    } else {
      await nearby.rejectConnection(request.endpointId);
    }
  }

  Future<void> _showGroupInviteDialog(NearbyGroupInvite invite) async {
    if (!mounted) return;

    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final existing = settings.threadById(invite.groupId);

    if (existing != null) {
      settings.createOrUpdateGroupThread(
        groupId: invite.groupId,
        title: invite.groupTitle,
        participantNodeIds: invite.participantNodeIds,
        participantNames: invite.participantNames,
      );
      return;
    }

    final accept = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Group Invite'),
        content: Text(
          '${invite.inviterName} invites you to “${invite.groupTitle}”.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Reject'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Accept'),
          ),
        ],
      ),
    );

    if (accept == true && mounted) {
      settings.createOrUpdateGroupThread(
        groupId: invite.groupId,
        title: invite.groupTitle,
        participantNodeIds: invite.participantNodeIds,
        participantNames: invite.participantNames,
      );

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Joined ${invite.groupTitle}.')));
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
          ? 'voice'
          : incoming.type == NearbyIncomingType.file
          ? 'file'
          : 'text',
      fileName: incoming.fileName,
      filePath: incoming.filePath,
      senderNodeId: incoming.senderNodeId ?? incoming.nodeId,
      senderName: incoming.senderName ?? incoming.displayName,
    );

    if (incoming.groupId != null) {
      if (incoming.groupParticipantNodeIds != null &&
          incoming.groupParticipantNames != null) {
        settings.createOrUpdateGroupThread(
          groupId: incoming.groupId!,
          title: incoming.groupTitle ?? 'MeshChat Group',
          participantNodeIds: incoming.groupParticipantNodeIds!,
          participantNames: incoming.groupParticipantNames!,
        );
      }

      final thread =
          settings.threadById(incoming.groupId!) ??
          settings.createOrUpdateGroupThread(
            groupId: incoming.groupId!,
            title: incoming.groupTitle ?? 'MeshChat Group',
            participantNodeIds: [incoming.nodeId],
            participantNames: {incoming.nodeId: incoming.displayName},
          );
      settings.addMessageToThreadId(thread.id, msg);
    } else {
      settings.addIncomingDirectMessage(
        deviceId: incoming.nodeId,
        title: incoming.displayName,
        message: msg,
      );
    }

    final notificationBody = incoming.type == NearbyIncomingType.voice
        ? 'New voice message'
        : incoming.type == NearbyIncomingType.file
        ? 'File received: ${incoming.fileName ?? 'file'}'
        : incoming.text;

    if (!_isAppInForeground && settings.notificationsEnabled) {
      AppNotifications.showMessage(
        title: incoming.groupId != null
            ? '${incoming.senderName ?? incoming.displayName} in group'
            : incoming.displayName,
        body: notificationBody,
      );
      return;
    }

    if (!settings.inAppNotificationsEnabled) return;

    showTopInAppNotification(
      context,
      accentColor: settings.accentColor,
      icon: incoming.type == NearbyIncomingType.voice
          ? Icons.mic
          : incoming.type == NearbyIncomingType.file
          ? Icons.attach_file
          : Icons.chat_bubble_outline,
      message: incoming.type == NearbyIncomingType.voice
          ? 'New voice message from ${incoming.senderName ?? incoming.displayName}'
          : incoming.type == NearbyIncomingType.file
          ? 'File from ${incoming.senderName ?? incoming.displayName}: ${incoming.fileName ?? 'file'}'
          : 'New message from ${incoming.senderName ?? incoming.displayName}',
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

// -----------------------------------------------------------------------------
// CHAT LIST
// -----------------------------------------------------------------------------
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
                            'No chats available. Connect to a device from Scan.',
                            textAlign: TextAlign.center,
                          ),
                        )
                      : ListView.builder(
                          itemCount: settings.threads.length,
                          itemBuilder: (context, i) {
                            final t = settings.threads[i];
                            final online = t.isGroup
                                ? t.participantNodeIds
                                      .where((id) => id != nearby.localNodeId)
                                      .any(nearby.isDeviceOnline)
                                : nearby.isDeviceOnline(t.deviceId);
                            final connected = t.isGroup
                                ? nearby.connectedOtherCountForGroup(t) > 0
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
                                    ? 'Group'
                                    : online
                                    ? 'Online'
                                    : 'Offline',
                                maxLines: 1,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    t.isGroup
                                        ? '${nearby.activeCountForThread(t)} active'
                                        : connected
                                        ? 'Connected'
                                        : online
                                        ? 'Online'
                                        : 'Offline',
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
                                      if (value == 'delete') {
                                        settings.deleteThread(t.id);
                                      }
                                    },
                                    itemBuilder: (_) => const [
                                      PopupMenuItem(
                                        value: 'delete',
                                        child: Text('Delete conversation'),
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

// -----------------------------------------------------------------------------
// SCAN PAGE
// -----------------------------------------------------------------------------
class NearbyScannerPage extends StatelessWidget {
  const NearbyScannerPage({super.key});

  Future<void> _showCreateGroupDialog(BuildContext context) async {
    final nearby = Provider.of<NearbyProvider>(context, listen: false);
    final settings = Provider.of<SettingsProvider>(context, listen: false);
    final devices = nearby.connectedDevices;

    if (devices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Connect to at least one device before creating a group.',
          ),
        ),
      );
      return;
    }

    final selected = <String>{};
    final titleController = TextEditingController(text: 'MeshChat Group');

    final create = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Create Group'),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: titleController,
                      decoration: const InputDecoration(
                        labelText: 'Group Name',
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
                            subtitle: const Text('Connected'),
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
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () => Navigator.pop(dialogContext, true),
                  child: const Text('Create'),
                ),
              ],
            );
          },
        );
      },
    );

    if (create == true) {
      final names = <String, String>{nearby.localNodeId: settings.alias};
      for (final d in devices.where((d) => selected.contains(d.nodeId))) {
        names[d.nodeId] = d.displayName;
      }

      final participants = <String>{nearby.localNodeId, ...selected}.toList();

      final thread = settings.createGroupThread(
        title: titleController.text,
        participantNodeIds: participants,
        participantNames: names,
      );

      await nearby.sendGroupInvite(
        groupThread: thread,
        targetNodeIds: selected.toList(),
      );

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Group created: ${thread.title}.')),
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
        title: const Text('Nearby Scan'),
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
                title: Text('My name: ${settings.alias}'),
                subtitle: Text(
                  '${nearby.status}\nPermanent ID: ${nearby.localNodeId}',
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
                          ? 'Advertising ON'
                          : 'Start Advertising',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    onPressed: nearby.startDiscovery,
                    child: Text(
                      nearby.isDiscovering ? 'Discovery ON' : 'Start Discovery',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _showCreateGroupDialog(context),
                icon: const Icon(Icons.group_add),
                label: const Text('Create Group from connected devices'),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: entries.isEmpty
                  ? const Center(
                      child: Text(
                        'No Nearby devices found yet.\nRun the app on two real Android phones.',
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
                            subtitle: Text('Node ID: ${device.nodeId}'),
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
                                isConnected ? 'Connected' : 'Connect',
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

// -----------------------------------------------------------------------------
// CHAT ROOM
// -----------------------------------------------------------------------------
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
    return lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.png') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
  }

  bool _isVideoFile(String? fileName) {
    if (fileName == null) return false;
    final lower = fileName.toLowerCase();
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.webm') ||
        lower.endsWith('.avi');
  }

  bool _isAudioFile(String? fileName) {
    if (fileName == null) return false;
    final lower = fileName.toLowerCase();
    return lower.endsWith('.m4a') ||
        lower.endsWith('.aac') ||
        lower.endsWith('.mp3') ||
        lower.endsWith('.wav') ||
        lower.endsWith('.ogg') ||
        lower.endsWith('.opus');
  }

  Future<void> _openFile(ChatMessage message) async {
    final path = message.filePath;
    if (path == null || path.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No file path available.')));
      return;
    }

    final file = File(path);
    if (!await file.exists()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The file no longer exists on this device.'),
        ),
      );
      return;
    }

    await OpenFilex.open(path);
  }

  Future<void> _downloadFile(ChatMessage message) async {
    final sourcePath = message.filePath;
    final fileName = message.fileName ?? 'meshchat_file';

    if (sourcePath == null || sourcePath.isEmpty) return;
    final sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) return;

    try {
      final bytes = await sourceFile.readAsBytes();
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save file',
        fileName: fileName,
        bytes: bytes,
      );

      if (savedPath == null) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('File saved: $fileName')));
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Save error: $e')));
    }
  }

  Widget _buildFileBubble(ChatMessage message) {
    final fileName = message.fileName ?? 'File';
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
            message.isVoice ? 'Voice message' : fileName,
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
                    message.isVoice || audioPreview ? 'Play' : 'Open',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: fileExists ? () => _downloadFile(message) : null,
                  icon: const Icon(Icons.file_download_outlined, size: 18),
                  label: const Text('Save'),
                ),
              ),
            ],
          ),
          if (!fileExists)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'File unavailable locally',
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

    if (thread.isGroup && nearby.connectedOtherCountForGroup(thread) == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No other connected group members.')),
      );
      return;
    }

    if (!thread.isGroup && !nearby.isDeviceConnected(thread.deviceId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Connect to the device before sending files.'),
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
      kind: 'file',
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
        text: '📎 File sent: ${picked.name}',
        isMine: true,
        timestamp: DateTime.now(),
        type: 'file',
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

    if (thread.isGroup && nearby.connectedOtherCountForGroup(thread) == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No other connected group members.')),
      );
      return;
    }

    if (!thread.isGroup && !nearby.isDeviceConnected(thread.deviceId)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Connect to the device before sending voice messages.'),
        ),
      );
      return;
    }

    final micOk = await requestMicrophonePermission();
    if (!micOk) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission is required.')),
      );
      return;
    }

    final hasRecorderPermission = await _audioRecorder.hasPermission();
    if (!hasRecorderPermission) return;

    final dir = await getTemporaryDirectory();
    final fileName = 'voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    final path = '${dir.path}/$fileName';

    await _audioRecorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: path,
    );

    setState(() => _isRecordingVoice = true);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Recording started. Tap the microphone again to send.'),
      ),
    );
  }

  Future<void> _stopAndSendVoice(ChatThread thread) async {
    final nearby = Provider.of<NearbyProvider>(context, listen: false);
    final settings = Provider.of<SettingsProvider>(context, listen: false);

    final path = await _audioRecorder.stop();
    setState(() => _isRecordingVoice = false);

    if (path == null || path.isEmpty) return;
    final file = File(path);
    if (!await file.exists()) return;

    final fileName = path.split(Platform.pathSeparator).last;
    final sentPath = await nearby.sendPathPayloadToThread(
      thread: thread,
      path: path,
      fileName: fileName,
      size: await file.length(),
      kind: 'voice',
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
        text: '🎤 Voice message',
        isMine: true,
        timestamp: DateTime.now(),
        type: 'voice',
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
        title: Text('Active members (${names.length})'),
        content: names.isEmpty
            ? const Text('No members connected right now.')
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
            child: const Text('OK'),
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
    final candidates = nearby.connectedDevices
        .where((d) => !thread.participantNodeIds.contains(d.nodeId))
        .toList();

    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No new connected devices to add.')),
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
              title: const Text('Add members'),
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
                      subtitle: const Text('Connected'),
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () => Navigator.pop(dialogContext, true),
                  child: const Text('Add'),
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

      final updateTargets = thread.participantNodeIds
          .where((id) => id != nearby.localNodeId)
          .where(nearby.isDeviceConnected)
          .toList();

      await nearby.sendGroupInvite(
        groupThread: thread,
        targetNodeIds: updateTargets,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Group updated. Sent to ${updateTargets.length} connected members.',
          ),
        ),
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
        appBar: AppBar(title: const Text('Chat')),
        body: const Center(child: Text('The conversation no longer exists.')),
      );
    }

    final nodeId = thread.deviceId;
    final online = thread.isGroup
        ? thread.participantNodeIds
              .where((id) => id != nearby.localNodeId)
              .any(nearby.isDeviceOnline)
        : nearby.isDeviceOnline(nodeId);
    final connected = thread.isGroup
        ? nearby.connectedOtherCountForGroup(thread) > 0
        : nearby.isDeviceConnected(nodeId);

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(thread.title),
            Text(
              thread.isGroup
                  ? '${nearby.activeCountForThread(thread)} active members'
                  : connected
                  ? 'Connected Nearby'
                  : online
                  ? 'Online, not connected'
                  : 'Offline',
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
              tooltip: 'Add connected members',
              onPressed: () => _showAddMembersDialog(thread, nearby, settings),
              icon: const Icon(Icons.person_add),
            ),
          if (thread.isGroup)
            TextButton.icon(
              onPressed: () => nearby.connectThreadDevices(thread),
              icon: const Icon(Icons.link),
              label: const Text('Connect'),
            ),
          if (thread.isGroup)
            TextButton.icon(
              onPressed: () => _showActiveMembers(thread, nearby),
              icon: const Icon(Icons.group),
              label: Text('${nearby.activeCountForThread(thread)} active'),
            ),
          if (!thread.isGroup && nodeId != null)
            TextButton.icon(
              onPressed: connected
                  ? () => nearby.disconnectDevice(nodeId)
                  : online
                  ? () => nearby.connectToDevice(nodeId)
                  : null,
              icon: Icon(connected ? Icons.link_off : Icons.link),
              label: Text(connected ? 'Disconnect' : 'Connect'),
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
                  ? 'Groups use normal peer-to-peer connections. Add/create groups only from connected devices.'
                  : connected
                  ? 'Nearby ready: messages and files are sent to the connected device.'
                  : online
                  ? 'Device online. Press Connect to resume the conversation.'
                  : 'Device offline or not detected right now.',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          Expanded(
            child: thread.messages.isEmpty
                ? const Center(child: Text('No messages yet.'))
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
                                            color: Theme.of(
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
                        hintText: 'Message...',
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

// -----------------------------------------------------------------------------
// SETTINGS PAGE
// -----------------------------------------------------------------------------
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
              '${settings.alias} • Permanent ID: ${nearby.localNodeId}',
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Nearby Alias',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _aliasController,
                    decoration: const InputDecoration(
                      labelText: 'My name',
                      hintText: 'Example: Alex, My Phone',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (value) async {
                      settings.updateAlias(value);
                      await nearby.restartNearby();

                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Alias saved and Nearby restarted.'),
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
                            content: Text('Alias saved and Nearby restarted.'),
                          ),
                        );
                      },
                      child: const Text('Save Alias'),
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'The name remains saved. The permanent ID does not change on restart, so conversations can be resumed when the device comes online.',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          SwitchListTile(
            title: const Text('Save History'),
            value: settings.saveHistory,
            onChanged: (v) => settings.toggleSaveHistory(v),
          ),
          SwitchListTile(
            title: const Text('System Notifications'),
            subtitle: const Text(
              'You will only receive phone notifications when the app is not open.',
            ),
            value: settings.notificationsEnabled,
            onChanged: (v) => settings.toggleNotifications(v),
          ),
          SwitchListTile(
            title: const Text('In-app Notifications'),
            subtitle: const Text(
              'Show a colored banner at the top while the app is open.',
            ),
            value: settings.inAppNotificationsEnabled,
            onChanged: (v) => settings.toggleInAppNotifications(v),
          ),
          ListTile(
            leading: const Icon(Icons.delete, color: Colors.red),
            title: const Text('Clear Chats'),
            onTap: () => settings.clearChats(),
          ),
          SwitchListTile(
            title: const Text('Dark Mode'),
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
