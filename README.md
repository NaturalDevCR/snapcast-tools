# Snapcast Tools 🎧

A collection of powerful bash scripts to manage **Snapcast Server** (Multi-room Audio) and **Snapclient** instances. These tools simplify installation, stream management, watchdog services, and client configuration, with special support for **Proxmox LXC** environments.

---

## 🛠️ Included Tools

| Script                  | Role       | Description                                                                  |
| :---------------------- | :--------- | :--------------------------------------------------------------------------- |
| `snapserver-manager.sh` | **SERVER** | Manage streams (TCP/Process), Watchdogs, Backups, and Snapserver config.     |
| `snapclient-setup.sh`   | **CLIENT** | Install Snapclient, fix ALSA card order, diagnostics, and Proxmox LXC setup. |

---

## 🖥️ 1. Snapstream Manager (Server)

`snapserver-manager.sh` is an all-in-one control panel for your Snapserver instance.

### ✨ Key Features

- **Easy Installation**: Deploys Snapserver, FFmpeg, and dependencies automatically.
- **Stream Management**:
  - **TCP Sources**: Easily add inputs from Windows/Linux PCs (via `tcp://`).
  - **Process Sources**: Add HLS/Web streams (e.g., **Azuracast**) or custom FFmpeg inputs (via `process://`).
  - **Smart Insertion**: Automatically configures `snapserver.conf` correctly.
- **Stability Watchdogs**:
  - **TCP Watchdog**: Enforces a strict limit of **1 connection per port**. If multiple connections/IPs clash, it kills all to force a clean reconnection.
  - **FFmpeg Watchdog**: Monitors pipe streams for freezes or silence and restarts them automatically.
- **Log Viewer**: Check logs for Snapserver, individual streams, and watchdogs.
- **Backups**: Create and restore tarball backups of your entire configuration.

### 🚀 Usage

Run as root:

```bash
sudo ./snapserver-manager.sh
```

**Or run directly via remote script:**

```bash
curl -s https://raw.githubusercontent.com/NaturalDevCR/snapcast-tools/main/snapserver-manager.sh | sudo bash
```

### 📋 Menu Options

- **1-3**: Add/Edit/Delete streams.
- **4 (Manage Sources)**: Add specific sources like **TCP** (for Spotify/PC audio) or **Process** (for Web Radio/Azuracast).
  - _Now supports configurable parameters (Idle Threshold, Timeout, Retry) during creation._
- **5 (TCP Watchdog)**: Essential for robustness. Kills zombie connections.
- **6 (Services)**: Restart Snapserver or specific stream services.
- **B (Backups)**: Save your work!

---

## 🔈 2. Snapclient Setup (Client)

`snapclient-setup.sh` simplifies the complex task of configuring audio clients, especially in **Proxmox LXC containers**.

### ✨ Key Features

- **Proxmox Support**: Automatically configures audio passthrough (`/dev/snd`) for LXC containers.
- **ALSA Fixer**: Corrects the dreaded "Audio Card vs USB Card" order issues on host reboots.
- **Diagnostics**: Generates a detailed health report of ALSA cards, modules, and logs.
- **Volume Control**: Sets initial volume persistence.

### 🚀 Usage

Run as root (can be run on the Proxmox Host or inside a Container/VM):

```bash
sudo ./snapclient-setup.sh
```

**Or run directly via remote script:**

```bash
curl -s https://raw.githubusercontent.com/NaturalDevCR/snapcast-tools/main/snapclient-setup.sh | sudo bash
```

### 📋 Workflow

1.  **Check Prerequisites**: Verifies ALSA modules and packages.
2.  **Fix Host ALSA Order** (Run on Host): ensures your DAC is always `card1` (or whichever you prefer).
3.  **Configure Snapclient**:
    - Selects the correct ALSA device.
    - Installs the correct `.deb` for your Debian version.
    - Connects to your Snapserver IP.

---

## 📦 Requirements

- **OS**: Debian 11/12, Ubuntu 20.04+, or Proxmox LXC (Debian-based).
- **Privileges**: Must run as `root`.
- **Dependencies**: `ffmpeg`, `curl`, `jq`, `alsa-utils` (installed automatically).

## 🤝 Contribution

Feel free to open issues or PRs to improve loop detection or add new stream types!

---

_Maintained by NaturalDevCR_
