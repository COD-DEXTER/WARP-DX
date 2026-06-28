# WARP DX (v2)
A simple, universal, and powerful interactive CLI menu for installing, managing, and using Cloudflare WARP. It dynamically supports Debian, Ubuntu, and Alpine Linux (highly optimized for stateless environments like Docker, Railway, and Fly.io) without requiring systemd or TUN/TAP device permissions in container environments.

It installs itself on first run as `dexter-warp`.

## 📦 Installation
Run this command in your terminal as root:
```bash
bash <(curl -Ls https://raw.githubusercontent.com/COD-DEXTER/WARP-DX/refs/heads/main/main.sh)

🚀 Features
Hybrid Platform Support: Automatically detects the OS and works seamlessly on Debian, Ubuntu, and Alpine Linux.
Zero-config SOCKS5 on Containers: On Alpine/Railway, it automatically configures and runs wireproxy (SOCKS5 Proxy on 127.0.0.1:10808) in user-space, bypassing systemd or TUN/TAP device requirements.
Native CLI Support on Linux: On Ubuntu/Debian, it installs and manages the official cloudflare-warp client natively.
IP Rotation: Features "Quick Reconnect" and "New Identity" to rotate and refresh your outbound SOCKS5 IP easily.
Global Command: Self-installs as a global terminal command: dexter-warp.
Built-in Diagnostics: Easily test your outgoing SOCKS5 IP, check connectivity, and verify proxy status.
🖥️ Supported Operating Systems
Ubuntu / Debian (Native warp-cli flow)
Alpine Linux / Docker / Railway (Lightweight wireproxy flow)
📢 Developer Contact
Telegram: @COD_DEXTER
