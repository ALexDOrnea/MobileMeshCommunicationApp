# MeshChat

**MeshChat** is a local peer-to-peer messaging app built with Flutter and Google Nearby Connections. It lets nearby Android devices discover each other, connect directly, and exchange text messages, files, images, videos, and voice messages without relying on a central server.

The app is designed around a simple idea: devices in the same physical area should be able to communicate quickly, privately, and directly.

---

## Features

### Peer-to-peer nearby messaging

MeshChat uses Nearby Connections to discover and connect Android devices in the same area. Once two devices are connected, they can exchange messages directly.

### Persistent device identity

Each device receives a persistent local node ID stored on the device. This allows MeshChat to recognize the same device again after restarting Nearby, closing the app, or reconnecting later.

### One-to-one chats

Users can connect to a nearby device and start a direct conversation. Conversations can be resumed when the other device comes back online.

### Group chats

MeshChat supports simple local group chats:

* create a group from online nearby devices;
* invite members with an accept/refuse popup;
* reconnect accepted group members without asking for permission every time;
* show how many group members are currently active;
* view the names of active members;
* add new members to an existing group.

### Text, file, and voice messages

Supported message types:

* text messages;
* file attachments;
* image and video previews;
* voice messages recorded directly in the chat.

### Local chat history

Chat history is stored locally using SharedPreferences. Users can disable history saving or clear all chats from Settings.

### Notifications

MeshChat can show local notifications when new messages arrive while the app is not in the foreground. Notifications can be turned on or off from Settings.

### Customization

Users can customize:

* device alias;
* dark mode;
* accent color;
* notification preference;
* chat history preference.

---

## How It Works

MeshChat uses a global `NearbyProvider` to keep Nearby advertising, discovery, connection state, and message routing active across the whole app.

The app is structured around three main tabs:

1. **Scan**
   Discover nearby devices, connect to peers, and create groups.

2. **Chats**
   View one-to-one and group conversations, active status, and recent messages.

3. **Settings**
   Manage alias, theme, notifications, chat history, and local identity information.

---

## Technical Overview

### Core technologies

* **Flutter** for the mobile UI.
* **Provider** for state management.
* **Nearby Connections** for peer discovery and peer-to-peer transport.
* **SharedPreferences** for local persistence.
* **File Picker** for selecting files.
* **OpenFilex** for opening received files.
* **Record** for voice message recording.
* **Flutter Local Notifications** for local background notifications.
* **Permission Handler** for Android runtime permissions.

### Main providers

#### `SettingsProvider`

Handles user settings and local chat history:

* alias;
* theme mode;
* accent color;
* notification preference;
* save history preference;
* saved chat threads;
* group thread creation;
* conversation deletion.

#### `NearbyProvider`

Handles the full Nearby lifecycle:

* advertising;
* discovery;
* connection requests;
* automatic group reconnection;
* text payloads;
* file payloads;
* voice message payloads;
* group invitations;
* online and connected status.

---

## Nearby Communication Model

Each device advertises a display name using this format:

```text
<alias>::<persistent-node-id>
```

The alias is user-facing. The persistent node ID is used internally to recognize the same device across sessions.

For group invitations, MeshChat temporarily adds encoded group metadata to the connection name. This lets the receiving device know that the incoming connection request is a group invitation rather than a normal peer-to-peer connection request.

---

## Message Types

MeshChat supports three internal message types:

```text
text
file
voice
```

Text messages are sent as byte payloads.

Files and voice messages are sent as Nearby file payloads with a metadata byte payload containing:

* payload ID;
* file name;
* file size;
* message kind;
* group ID, when applicable;
* sender node ID;
* sender display name.

---

## Group Chat Behavior

Groups are intentionally simple and local-first.

When a group is created:

1. The creator selects online nearby devices.
2. Each selected device receives a group invite popup.
3. If accepted, the group conversation is created locally on that device.
4. Future group reconnects are accepted automatically for known group members.

Messages are delivered only to members who are connected at the time of sending.

### Current group limitations

MeshChat does not currently provide:

* offline message sync;
* message delivery receipts;
* group admin roles;
* member removal;
* message encryption layer on top of Nearby;
* cloud backup;
* cross-device history sync.

These can be added later if the project evolves beyond local nearby communication.

---

## Permissions

MeshChat requires several Android permissions depending on device version and features used.

Common permissions include:

* location access for nearby discovery;
* Bluetooth scan, advertise, and connect permissions;
* nearby Wi-Fi devices permission;
* microphone permission for voice messages;
* notification permission for Android 13+ notifications.

Example Android manifest permissions:

```xml
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.NEARBY_WIFI_DEVICES" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

---

## Installation

Clone the project and install dependencies:

```bash
flutter pub get
```

Run on a real Android device:

```bash
flutter run
```

Nearby Connections should be tested on real Android devices. Emulators are not recommended for full Nearby functionality.

---

## Required Dependencies

The project uses packages such as:

```yaml
dependencies:
  flutter:
    sdk: flutter

  cupertino_icons: ^1.0.8
  shared_preferences: ^2.5.3
  uuid: ^4.5.1
  provider: ^6.1.5+1
  permission_handler: ^11.3.1
  nearby_connections: ^4.3.0
  file_picker: ^8.1.7
  path_provider: ^2.1.5
  open_filex: ^4.6.0
  record: ^6.2.0
  flutter_local_notifications: ^19.5.0

dev_dependencies:
  flutter_test:
    sdk: flutter

  flutter_lints: ^6.0.0
  flutter_launcher_icons: ^0.14.4
```

---

## Android Setup Notes

### Core library desugaring

`flutter_local_notifications` requires core library desugaring.

In `android/app/build.gradle.kts`:

```kotlin
android {
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
```

### Minimum SDK

A minimum SDK of 23 is recommended:

```kotlin
defaultConfig {
    minSdk = 23
}
```

---

## App Icon

MeshChat uses `flutter_launcher_icons` to generate Android and iOS launcher icons.

Example configuration:

```yaml
flutter_launcher_icons:
  android: true
  ios: true
  image_path: "assets/icon/meshchat_app_icon_transparent.png"
  adaptive_icon_background: "#0052D4"
  adaptive_icon_foreground: "assets/icon/meshchat_app_icon_transparent.png"
```

Generate icons with:

```bash
dart run flutter_launcher_icons
```

---

## Running and Testing

For best results, test with at least two physical Android phones.

Recommended test flow:

1. Install the app on both devices.
2. Open the app on both devices.
3. Grant Nearby, Bluetooth, Wi-Fi, location, microphone, and notification permissions.
4. Go to the **Scan** tab on both devices.
5. Wait for each device to appear.
6. Connect peer-to-peer or create a group.
7. Send text messages, files, and voice messages.
8. Minimize one device and test local notifications.

---

## Known Limitations

### Background reliability

The app does not currently use a native Android foreground service. Nearby may continue working while the app is minimized, but Android can stop background activity depending on battery optimization, OS version, and device manufacturer.

For production-grade background communication, a foreground service should be implemented.

### No offline message queue

If a group member is offline or disconnected, messages are not queued for later delivery.

### No cloud infrastructure

MeshChat is intentionally local-first. It does not use cloud servers, accounts, or remote databases.

---

## Roadmap Ideas

Possible future improvements:

* foreground service for stronger background reliability;
* offline message queue and resend on reconnect;
* delivery/read receipts;
* encrypted local payload layer;
* group member removal;
* group admin roles;
* message search;
* better audio playback UI;
* file transfer progress UI;
* QR-based trusted device pairing;
* local database migration from SharedPreferences to Hive, Isar, or SQLite.

---

## Project Philosophy

MeshChat is built as a practical experiment in local-first communication. It prioritizes direct nearby connectivity, simple UX, and minimal infrastructure.

The goal is to make nearby device communication feel as simple as opening a chat app, selecting a device, and sending a message.

---

## License

This project is currently private. Add a license before publishing or distributing publicly.
