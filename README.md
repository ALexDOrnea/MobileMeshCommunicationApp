# 🔵 MeshUp

> Experimental BLE chat app built with Flutter — a first step toward a future mesh network messaging system.

---

## ✨ Overview

MeshUp is a prototype mobile app that explores **Bluetooth Low Energy (BLE)** communication between nearby devices.

Right now, it supports basic BLE-based messaging and device discovery.  
The long-term goal is to evolve it into a **decentralized mesh messaging app**, where devices can relay messages without relying on internet access.

---

## 🚀 Current Features

- 🔎 BLE device scanning
- 🔗 Connect to nearby BLE devices
- 📤 Send messages over BLE
- 📥 Receive messages from connected devices
- 💬 Multiple chat threads
- 💾 Optional chat saving (user-controlled)
- ⚡ Fast iteration with Flutter hot reload

---

## 🧠 How It Works

BLE communication is based on a custom service and two characteristics:

- **Service UUID** → defines the communication channel
- **TX Characteristic** → used to send messages
- **RX Characteristic** → used to receive messages

```dart
const String kServiceUuid = "12345678-1234-1234-1234-1234567890ab";
const String kTxCharacteristicUuid = "12345678-1234-1234-1234-1234567890ac";
const String kRxCharacteristicUuid = "12345678-1234-1234-1234-1234567890ad";
