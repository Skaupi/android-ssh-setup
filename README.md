# Android SSH Setup

SSH setup between Android (Termux) and Linux.

## Android Manual Steps

```bash
pkg update && pkg upgrade -y
pkg install openssh net-tools -y
passwd          # Set password
sshd            # Start SSH
whoami && ifconfig  # Get username and IP
```

## Linux

```bash
./setup-android-ssh.sh
```

## What It Does

**Prompts for:**
- Android IP, Termux username, connection name, SSH port

**Configures:**
1. Generates ed25519 SSH key pair
2. Adds host to `~/.ssh/config`
3. Deploys public key to Android
4. Fixes permissions (700 ~/.ssh, 600 authorized_keys)
5. Hardens sshd_config (disables password auth)
6. Restarts sshd
7. Optional: Creates Termux:Boot script for persistent sshd

**Result:** `ssh <connection-name>` works

## Termux:Boot (Optional)

**Requires:**
- Termux:Boot app (F-Droid)
- Termux:API app (optional, for wake lock)

**Critical:**
- Settings → Apps → Termux → Battery → Unrestricted
- Settings → Apps → Termux:Boot → Battery → Unrestricted

Runs sshd on Android boot.
