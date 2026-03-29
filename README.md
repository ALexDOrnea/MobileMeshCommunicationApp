# 📱 MobileMeshCommunicationApp

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Android-green.svg)]()
[![Build Status](https://img.shields.io/badge/Build-Passing-brightgreen.svg)]()

**MobileMeshCommunicationApp** is a cutting-edge mobile solution designed to enable seamless communication between devices without the need for internet access or centralized infrastructure (Cellular Data/Wi-Fi). 

By leveraging **Mesh Networking** technology, each device acts as a node in an ad-hoc network, relaying messages directly to nearby peers.

---

## 🚀 Key Features

-   **Zero-Infrastructure Communication:** Send messages in remote areas, during natural disasters, or in crowded events where towers are congested.
-   **Peer-to-Peer (P2P):** Direct device-to-device connectivity using Bluetooth Low Energy (BLE) and Wi-Fi Direct.
-   **Multi-hop Routing:** Messages can jump through multiple devices to reach a destination outside the sender's immediate range.
-   **Auto-Healing Topology:** The network dynamically reconfigures itself as users move in and out of range.
-   **Battery Optimized:** Designed with low-energy protocols to ensure minimal impact on device battery life.

## 🛠 Tech Stack

-   **Language:** Kotlin / Java
-   **Protocol:** Bluetooth Low Energy (BLE) & Wi-Fi Aware/Direct
-   **Architecture:** MVVM (Model-View-ViewModel) for a clean, testable codebase.
-   **Local Storage:** Room Database for persistent message history.
-   **Concurrency:** Kotlin Coroutines for smooth background processing.

## 📦 Getting Started

To get a local copy up and running, follow these simple steps:

### Prerequisites
* Android Studio (Latest Version)
* At least two physical Android devices (Mesh features cannot be fully tested on Emulators).

### Installation
1.  **Clone the repo:**
    ```bash
    git clone [https://github.com/ALexDOrnea/MobileMeshCommunicationApp.git](https://github.com/ALexDOrnea/MobileMeshCommunicationApp.git)
    ```
2.  **Open in Android Studio:**
    Select `File > Open` and navigate to the project folder.
3.  **Sync Gradle:**
    Allow the IDE to download necessary dependencies.
4.  **Run:**
    Deploy the app to your physical devices.

## 📖 How It Works

1.  **Permissions:** Grant Location and Bluetooth permissions (required for P2P discovery).
2.  **Discovery:** The app automatically scans for nearby "nodes" running the same protocol.
3.  **Connection:** Once a peer is found, a secure socket is established.
4.  **Chat:** Start typing! Your message will find the shortest path through the mesh to the recipient.

## 🗺 Roadmap

- [ ] **End-to-End Encryption:** Implementation of Signal Protocol for private messaging.
- [ ] **File Sharing:** Support for offline image and document transfers.
- [ ] **Desktop Client:** Cross-platform support for Windows/Linux nodes.
- [ ] **Public API:** Allowing other apps to use the mesh layer for data transfer.

## 🤝 Contributing

Contributions are what make the open-source community such an amazing place to learn, inspire, and create. 
1. **Fork** the Project.
2. Create your **Feature Branch** (`git checkout -b feature/AmazingFeature`).
3. **Commit** your Changes (`git commit -m 'Add some AmazingFeature'`).
4. **Push** to the Branch (`git push origin feature/AmazingFeature`).
5. Open a **Pull Request**.

## 📄 License

Distributed under the MIT License. See `LICENSE` for more information.

---

⭐ **If you find this project useful, please give it a Star!**

Developed by [Alex Dornea](https://github.com/ALexDOrnea)