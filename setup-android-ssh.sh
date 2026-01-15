#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/templates"

RED='\033[0;31m'
NC='\033[0m'

if [ ! -d "$TEMPLATE_DIR" ]; then
    mkdir -p "$TEMPLATE_DIR"
fi

read -p "Android IP: " ANDROID_IP
read -p "Termux username: " TERMUX_USER
read -p "Connection name [android-phone]: " CONN_NAME
CONN_NAME=${CONN_NAME:-android-phone}
read -p "SSH port [8022]: " SSH_PORT
SSH_PORT=${SSH_PORT:-8022}

KEY_NAME="id_${CONN_NAME//-/_}"
KEY_PATH="$HOME/.ssh/$KEY_NAME"

if ! pacman -Q openssh &>/dev/null; then
    sudo pacman -S --noconfirm openssh
fi

# Find existing SSH keys
EXISTING_KEYS=()
for key in "$HOME/.ssh/"*; do
    if [ -f "$key" ] && [ -f "${key}.pub" ] && [[ ! "$key" =~ \.pub$ ]]; then
        EXISTING_KEYS+=("$key")
    fi
done

if [ -f "$KEY_PATH" ]; then
    read -p "Key $KEY_NAME exists. (u)se / (o)verwrite / (n)ew / (s)elect other / (c)ancel: " key_choice
    case $key_choice in
        o|O)
            ssh-keygen -t ed25519 -C "linux_to_${CONN_NAME}" -f "$KEY_PATH" -N ""
            ;;
        n|N)
            read -p "New key name: " new_key_name
            KEY_PATH="$HOME/.ssh/$new_key_name"
            if [ -f "$KEY_PATH" ]; then
                echo "Key already exists. Aborted."
                exit 1
            fi
            ssh-keygen -t ed25519 -C "linux_to_${CONN_NAME}" -f "$KEY_PATH" -N ""
            ;;
        s|S)
            if [ ${#EXISTING_KEYS[@]} -eq 0 ]; then
                echo "No other keys found. Creating new key."
                ssh-keygen -t ed25519 -C "linux_to_${CONN_NAME}" -f "$KEY_PATH" -N ""
            else
                echo "Available keys:"
                for i in "${!EXISTING_KEYS[@]}"; do
                    echo "  $((i+1))) ${EXISTING_KEYS[$i]}"
                done
                read -p "Select key (1-${#EXISTING_KEYS[@]}): " key_selection
                if [[ "$key_selection" =~ ^[0-9]+$ ]] && [ "$key_selection" -ge 1 ] && [ "$key_selection" -le "${#EXISTING_KEYS[@]}" ]; then
                    KEY_PATH="${EXISTING_KEYS[$((key_selection-1))]}"
                else
                    echo "Invalid selection. Aborted."
                    exit 1
                fi
            fi
            ;;
        c|C)
            echo "Aborted."
            exit 0
            ;;
        u|U|*)
            ;;
    esac
else
    if [ ${#EXISTING_KEYS[@]} -gt 0 ]; then
        read -p "Key $KEY_NAME doesn't exist. (n)ew / (s)elect existing / (c)ancel: " key_choice
        case $key_choice in
            s|S)
                echo "Available keys:"
                for i in "${!EXISTING_KEYS[@]}"; do
                    echo "  $((i+1))) ${EXISTING_KEYS[$i]}"
                done
                read -p "Select key (1-${#EXISTING_KEYS[@]}): " key_selection
                if [[ "$key_selection" =~ ^[0-9]+$ ]] && [ "$key_selection" -ge 1 ] && [ "$key_selection" -le "${#EXISTING_KEYS[@]}" ]; then
                    KEY_PATH="${EXISTING_KEYS[$((key_selection-1))]}"
                else
                    echo "Invalid selection. Aborted."
                    exit 1
                fi
                ;;
            c|C)
                echo "Aborted."
                exit 0
                ;;
            n|N|*)
                ssh-keygen -t ed25519 -C "linux_to_${CONN_NAME}" -f "$KEY_PATH" -N ""
                ;;
        esac
    else
        ssh-keygen -t ed25519 -C "linux_to_${CONN_NAME}" -f "$KEY_PATH" -N ""
    fi
fi

SSH_CONFIG="$HOME/.ssh/config"
chmod 700 "$HOME/.ssh"

# Check for ControlMaster config
if ! grep -qi "^[[:space:]]*ControlMaster" "$SSH_CONFIG" 2>/dev/null; then
    echo ""
    echo "ControlMaster not detected. Enables connection reuse for faster SSH (recommended for health monitoring)."
    read -p "Add ControlMaster? (g)lobal / (h)ost-only / (n)o [g]: " control_choice
    control_choice=${control_choice:-g}

    case $control_choice in
        g|G)
            mkdir -p "$HOME/.ssh/sockets"
            if ! grep -q "^Host \*$" "$SSH_CONFIG" 2>/dev/null; then
                cat >> "$SSH_CONFIG" <<EOF

Host *
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%r@%h-%p
    ControlPersist 10m
EOF
            else
                sed -i "/^Host \*$/a\\    ControlMaster auto\\n    ControlPath ~/.ssh/sockets/%r@%h-%p\\n    ControlPersist 10m" "$SSH_CONFIG"
            fi
            echo "Added global ControlMaster config"
            ;;
        h|H)
            mkdir -p "$HOME/.ssh/sockets"
            ADD_HOST_CONTROL=true
            ;;
        n|N|*)
            ;;
    esac
else
    mkdir -p "$HOME/.ssh/sockets"
fi

if grep -q "^Host $CONN_NAME$" "$SSH_CONFIG" 2>/dev/null; then
    read -p "Host exists in config. Replace? (y/n): " replace
    if [[ $replace =~ ^[Yy]$ ]]; then
        sed -i "/^Host $CONN_NAME$/,/^$/d" "$SSH_CONFIG"
    fi
fi

if [[ ! $replace =~ ^[Nn]$ ]] && ! grep -q "^Host $CONN_NAME$" "$SSH_CONFIG" 2>/dev/null; then
    if [ "$ADD_HOST_CONTROL" = true ]; then
        cat >> "$SSH_CONFIG" <<EOF

Host $CONN_NAME
    HostName $ANDROID_IP
    User $TERMUX_USER
    Port $SSH_PORT
    IdentityFile $KEY_PATH
    ServerAliveInterval 15
    ServerAliveCountMax 3
    ControlMaster auto
    ControlPath ~/.ssh/sockets/%r@%h-%p
    ControlPersist 10m
EOF
    else
        cat >> "$SSH_CONFIG" <<EOF

Host $CONN_NAME
    HostName $ANDROID_IP
    User $TERMUX_USER
    Port $SSH_PORT
    IdentityFile $KEY_PATH
    ServerAliveInterval 15
    ServerAliveCountMax 3
EOF
    fi
fi

echo "Deploying key (enter Termux password)..."
KEY_DEPLOYED=false
if command -v ssh-copy-id &>/dev/null; then
    if ssh-copy-id -p "$SSH_PORT" -i "${KEY_PATH}.pub" "$TERMUX_USER@$ANDROID_IP" 2>/dev/null; then
        KEY_DEPLOYED=true
    else
        echo -e "${RED}Failed. Manual: copy this to ~/.ssh/authorized_keys on Android:${NC}"
        cat "${KEY_PATH}.pub"
        read -p "Press Enter when done..."
        KEY_DEPLOYED=true
    fi
else
    if cat "${KEY_PATH}.pub" | ssh "$TERMUX_USER@$ANDROID_IP" -p "$SSH_PORT" "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys" 2>/dev/null; then
        KEY_DEPLOYED=true
    fi
fi

if [ "$KEY_DEPLOYED" = true ]; then
    ssh -p "$SSH_PORT" -i "$KEY_PATH" "$TERMUX_USER@$ANDROID_IP" "chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys" 2>/dev/null

    ssh -p "$SSH_PORT" -i "$KEY_PATH" "$TERMUX_USER@$ANDROID_IP" bash <<'EOFANDROID' 2>/dev/null
cp $PREFIX/etc/ssh/sshd_config $PREFIX/etc/ssh/sshd_config.backup 2>/dev/null || true

if grep -q "^PubkeyAuthentication" $PREFIX/etc/ssh/sshd_config; then
    sed -i 's/^PubkeyAuthentication.*/PubkeyAuthentication yes/' $PREFIX/etc/ssh/sshd_config
else
    echo "PubkeyAuthentication yes" >> $PREFIX/etc/ssh/sshd_config
fi

if grep -q "^PasswordAuthentication" $PREFIX/etc/ssh/sshd_config; then
    sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' $PREFIX/etc/ssh/sshd_config
else
    echo "PasswordAuthentication no" >> $PREFIX/etc/ssh/sshd_config
fi

if grep -q "^ChallengeResponseAuthentication" $PREFIX/etc/ssh/sshd_config; then
    sed -i 's/^ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' $PREFIX/etc/ssh/sshd_config
else
    echo "ChallengeResponseAuthentication no" >> $PREFIX/etc/ssh/sshd_config
fi
EOFANDROID

    ssh -p "$SSH_PORT" -i "$KEY_PATH" "$TERMUX_USER@$ANDROID_IP" "pkill sshd; sshd" 2>/dev/null

    read -p "Setup Termux:Boot? (y/n): " setup_boot
    if [[ $setup_boot =~ ^[Yy]$ ]]; then
        if ssh -p "$SSH_PORT" -i "$KEY_PATH" "$TERMUX_USER@$ANDROID_IP" "command -v termux-wake-lock" >/dev/null 2>&1; then
            USE_WAKELOCK=true
        else
            echo "termux-api not found. Install: pkg install termux-api"
            read -p "Continue without wake lock? (y/n): " continue_boot
            if [[ ! $continue_boot =~ ^[Yy]$ ]]; then
                USE_WAKELOCK=false
            else
                USE_WAKELOCK=false
            fi
        fi

        if [[ $continue_boot =~ ^[Yy]$ ]] || [ "$USE_WAKELOCK" = true ]; then
            BOOT_SCRIPT_CONTENT=$(cat "$TEMPLATE_DIR/termux-boot-sshd.sh")

            if [ "$USE_WAKELOCK" = false ]; then
                BOOT_SCRIPT_CONTENT=$(echo "$BOOT_SCRIPT_CONTENT" | grep -v "termux-wake-lock")
            fi

            ssh -p "$SSH_PORT" -i "$KEY_PATH" "$TERMUX_USER@$ANDROID_IP" bash <<EOFBOOT 2>/dev/null
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/start-sshd <<'EOFSCRIPT'
$BOOT_SCRIPT_CONTENT
EOFSCRIPT
chmod +x ~/.termux/boot/start-sshd
EOFBOOT

            if [ $? -eq 0 ]; then
                echo ""
                echo "Termux:Boot script created"
                echo ""
                echo "Required:"
                echo "  - Termux:Boot app (F-Droid)"
                if [ "$USE_WAKELOCK" = true ]; then
                    echo "  - Termux:API app (F-Droid)"
                fi
                echo ""
                echo "CRITICAL - Disable battery optimization:"
                echo "  Settings → Apps → Termux → Battery → Unrestricted"
                echo "  Settings → Apps → Termux:Boot → Battery → Unrestricted"
                if [ "$USE_WAKELOCK" = true ]; then
                    echo ""
                    echo "Grant display permission:"
                    echo "  Settings → Apps → Termux → Display over other apps → Enable"
                fi
                echo ""
                echo "Reboot Android to activate"
            else
                echo -e "${RED}Failed to create boot script${NC}"
            fi
        fi
    fi
fi

if ssh -o ConnectTimeout=5 -o BatchMode=yes "$CONN_NAME" "exit" 2>/dev/null; then
    echo "Done. SSH: ssh $CONN_NAME"
else
    echo -e "${RED}SSH test failed. Debug: ssh -vvv $CONN_NAME${NC}"
fi
