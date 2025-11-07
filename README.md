# ProxServe-S5 🛜

A lightweight PowerShell tray launcher for SSH SOCKS5 proxies.  
ProxServe‑S5 runs silently in the background, manages retries, and provides a live status window with stats.

---

## ✨ Features
- Tray icon with **Status** and **Exit** options
- Auto‑reconnecting SSH SOCKS5 proxy
- Configurable retries (`MAX_TRIES`) and session timeout (`MAX_WAIT`)
- Auto-login using SSH keyfile (***no password support available yet***)

---

## 📦 Installation
Download the latest release that matches your Windows device specifications.

---

## ⚙️ Configuration
On first run, ProxServe‑S5 creates a config file at `%APPDATA%\ProxServe-S5\config.ini`

Edit `config.ini` to set your proxy details:

```ini
PROXY_IP		→	Proxy server's IP											(default: 127.0.0.1)
PROXY_PORT		→	Proxy server's Port											(default: 22)

DYNAMIC_PORT	→	SOCKS5 Forwarding											(default: 1080)
MAX_TRIES		→	Maximum amount of reconnecting attempt tries until exit		(default: 10)
MAX_WAIT		→	Maximum amount of time until session restart for retrying	(default: 0)
SSH_USERNAME	→	SSH username to use to login into the SSH session			(default: your username)
SSH_KEYFILE		→	SSH keyfile to use to auto-login, empty for automatic file	(default: none)
```
