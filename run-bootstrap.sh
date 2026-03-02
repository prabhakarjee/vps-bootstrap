#!/usr/bin/env bash
# run-bootstrap.sh — Public entry point for VPS bootstrap
# Version: 2026-03-02-V24
#
# Forces bash if accidentally run by sh
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi

set -eu
set -o pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# ─── Helpers ───────────────────────────────────────────────────────────────
wait_for_apt() {
    local count=0
    local max=60 # 10 minutes (10s * 60)
    echo -n "⏳ Waiting for apt lock..."
    while fuser /var/lib/dpkg/lock >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        echo -n "."
        sleep 10
        count=$((count + 1))
        if [ $count -ge $max ]; then
            echo ""
            echo "⚠️  Apt lock still held after 10 minutes. Attempting to proceed anyway..."
            break
        fi
    done
    echo " done."
}

SECRETS_DIR="${SECRETS_DIR:-/opt/secrets}"
BW_ENV="$SECRETS_DIR/bw.env"
INSTALL_DIR="${INSTALL_DIR:-/opt/infra}"
GITHUB_REPO_NAME="${GITHUB_REPO_NAME:-infra-core}"
BRANCH="${BRANCH:-master}"

echo "╔════════════════════════════════════════════╗"
echo "║  VPS Bootstrap (Bitwarden → infra-core)    ║"
echo "╚════════════════════════════════════════════╝"
echo ""

if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Run as root: sudo bash run-bootstrap.sh"
    exit 1
fi

if [ ! -f /etc/os-release ]; then
    echo "❌ Cannot detect OS"
    exit 1
fi

. /etc/os-release
echo "📊 Detected: $PRETTY_NAME"
if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
    echo "⚠️  This script is optimized for Ubuntu/Debian."
    read -r -p "Continue anyway? (y/N): " confirm 2>/dev/null || true
    [[ "${confirm:-n}" != "y" ]] && exit 1
fi
echo ""

# ─── BSM access token (single credential, persisted to bsm.token) ───────────
mkdir -p "$SECRETS_DIR"
chmod 750 "$SECRETS_DIR"

echo "  Bitwarden Secrets Manager (BSM) access token is used to fetch all infra secrets."
echo "  Generate at: vault.bitwarden.com → Secrets Manager → Machine Accounts → New Token"
echo "  The token is written to $SECRETS_DIR/bsm.token (root-only) and reused on every run."
echo ""

BSM_TOKEN_FILE="$SECRETS_DIR/bsm.token"
if [ -n "${BSM_ACCESS_TOKEN:-}" ]; then
    echo "📝 Using BSM_ACCESS_TOKEN from environment."
    _bsm_token="$BSM_ACCESS_TOKEN"
elif [ -s "$BSM_TOKEN_FILE" ] && command -v bws &>/dev/null; then
    _bsm_token=$(tr -d '[:space:]' < "$BSM_TOKEN_FILE")
    echo "📝 Using cached BSM token from $BSM_TOKEN_FILE"
elif [ -t 0 ]; then
    printf "   Paste BSM Access Token: "
    read -rs _bsm_token; echo ""
else
    echo "❌ BSM_ACCESS_TOKEN not set in environment and no TTY available."
    exit 1
fi

if [ -z "${_bsm_token:-}" ]; then
    echo "❌ BSM token cannot be empty."
    exit 1
fi

echo "$_bsm_token" > "$BSM_TOKEN_FILE"
chmod 640 "$BSM_TOKEN_FILE"
chown root:deploy "$BSM_TOKEN_FILE" 2>/dev/null || true
echo "   ✓ BSM token stored → $BSM_TOKEN_FILE"
echo ""

# ─── Dependencies ───────────────────────────────────────────────────────────
wait_for_apt
echo "📦 Ensuring system dependencies (git, curl, unzip, jq)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl unzip jq > /dev/null 2>&1
echo "   ✓ Dependencies ready"
echo ""

# Install bws CLI if not present (needed to fetch GitHub PAT + bootstrap env below)
if ! command -v bws &>/dev/null; then
    echo "📦 Installing bws CLI to /usr/local/bin..."
    _bws_url=$(curl -s "https://api.github.com/repos/bitwarden/sdk-sm/releases" \
        | grep -oP '"browser_download_url": "\K(.*bws-x86_64-unknown-linux-gnu.*\.zip)(?=")' | head -1 2>/dev/null) || true
    if [ -n "$_bws_url" ]; then
        curl -sL "$_bws_url" -o /tmp/bws.zip
        # Extract and ensure it actually exists
        unzip -o -q /tmp/bws.zip bws -d /usr/local/bin/
        chmod +x /usr/local/bin/bws
        rm -f /tmp/bws.zip
        if ! command -v bws &>/dev/null; then
             echo "❌ bws extraction failed or /usr/local/bin not in PATH"
             exit 1
        fi
        echo "   ✓ bws installed successfully"
    else
        echo "❌ Could not find bws download URL. Bitwarden might have changed their release page structure again."
        exit 1
    fi
    unset _bws_url
fi

# ─── Fetch GitHub PAT and bootstrap env from BSM ─────────────────────────────
if ! command -v bws &>/dev/null; then
    echo "❌ bws CLI not found. Check install step above."
    exit 1
fi
_bsm_token=$(tr -d '[:space:]' < "$BSM_TOKEN_FILE" 2>/dev/null)

# Automatic Discovery: If IDs are missing, find them by name
echo "🔍 Discovering secret IDs from Bitwarden..."
_secrets_err=$(mktemp)
_secrets_json=$(BWS_ACCESS_TOKEN="$_bsm_token" bws secret list --output json 2>"$_secrets_err") || true
_err_content=$(cat "$_secrets_err")
rm -f "$_secrets_err"

if [ -n "$_err_content" ]; then
    echo "   ⚠️  Bitwarden CLI reported an error:"
    echo "      $_err_content"
fi

if [ -n "$_secrets_json" ] && [ "$_secrets_json" != "[]" ]; then
    _count=$(echo "$_secrets_json" | jq '. | length' 2>/dev/null || echo "0")
    echo "   ✓ Connected to BSM: $_count secrets found in current project."
    
    # helper: find by exact key, then case-insensitive, then partial match
    find_id() {
        local _k="$1"
        local _id=""
        # 1. Exact match
        _id=$(echo "$_secrets_json" | jq -r ".[] | select(.key == \"$_k\") | .id" 2>/dev/null | head -1)
        # 2. Case-insensitive match (fallback)
        if [ -z "$_id" ] || [ "$_id" = "null" ]; then
            _id=$(echo "$_secrets_json" | jq -r ".[] | select(.key | ascii_downcase == (\"$_k\" | ascii_downcase)) | .id" 2>/dev/null | head -1)
        fi
        # 3. Partial match (last resort fallback)
        if [ -z "$_id" ] || [ "$_id" = "null" ]; then
            _id=$(echo "$_secrets_json" | jq -r ".[] | select(.key | ascii_downcase | contains(\"$_k\" | ascii_downcase)) | .id" 2>/dev/null | head -1)
        fi
        [ "$_id" = "null" ] && _id=""
        echo "$_id"
    }

    [ -z "${BSM_ID_GITHUB_PAT:-}" ] || [ "${BSM_ID_GITHUB_PAT}" = "00000000-0000-0000-0000-000000000000" ] && BSM_ID_GITHUB_PAT=$(find_id "GITHUB_PAT")
    [ -z "${BSM_ID_BOOTSTRAP_ENV:-}" ] || [ "${BSM_ID_BOOTSTRAP_ENV}" = "00000000-0000-0000-0000-000000000000" ] && BSM_ID_BOOTSTRAP_ENV=$(find_id "BOOTSTRAP_ENV")
    [ -z "${BSM_ID_DEPLOY_PASSWORD:-}" ] || [ "${BSM_ID_DEPLOY_PASSWORD}" = "00000000-0000-0000-0000-000000000000" ] && BSM_ID_DEPLOY_PASSWORD=$(find_id "DEPLOY_PASSWORD")
    
    # Discovery with fallback (Tailscale specifically)
    if [ -z "${BSM_ID_TAILSCALE_KEY:-}" ] || [ "${BSM_ID_TAILSCALE_KEY}" = "00000000-0000-0000-0000-000000000000" ]; then
        BSM_ID_TAILSCALE_KEY=$(find_id "TAILSCALE_KEY")
    fi

    # Discovery for Phase 2: Certs, R2, Kuma, Alerts
    BSM_ID_ORIGIN_CERT=$(find_id "ORIGIN_CERT")
    BSM_ID_ORIGIN_KEY=$(find_id "ORIGIN_KEY")
    BSM_ID_R2_ENDPOINT=$(find_id "R2_ENDPOINT")
    BSM_ID_R2_BUCKET=$(find_id "R2_BUCKET")
    BSM_ID_R2_ACCESS_KEY_ID=$(find_id "R2_ACCESS_KEY_ID")
    BSM_ID_R2_SECRET_ACCESS_KEY=$(find_id "R2_SECRET_ACCESS_KEY")
    BSM_ID_KUMA_USER=$(find_id "KUMA_USER")
    BSM_ID_KUMA_PASS=$(find_id "KUMA_PASS")
    BSM_ID_TELEGRAM_BOT_TOKEN=$(find_id "TELEGRAM_BOT_TOKEN")
    BSM_ID_TELEGRAM_CHAT_ID=$(find_id "TELEGRAM_CHAT_ID")
    BSM_ID_SMTP_HOST=$(find_id "SMTP_HOST")
    BSM_ID_SMTP_PORT=$(find_id "SMTP_PORT")
    BSM_ID_SMTP_FROM=$(find_id "SMTP_FROM")
    BSM_ID_SMTP_TO=$(find_id "SMTP_TO")
    BSM_ID_BACKUP_KEY=$(find_id "BACKUP_KEY")
else
    echo "   ⚠️  No secrets found in BSM or 'bws secret list' returned empty."
    echo "      Check your BSM Access Token permissions or Project membership."
fi

GITHUB_PAT=""
if [ -n "${BSM_ID_GITHUB_PAT:-}" ] && [ "${BSM_ID_GITHUB_PAT}" != "00000000-0000-0000-0000-000000000000" ]; then
    GITHUB_PAT=$(BWS_ACCESS_TOKEN="$_bsm_token" bws secret get "$BSM_ID_GITHUB_PAT" --output json 2>/dev/null \
        | jq -r ".value" 2>/dev/null) || true
fi
if [ -z "$GITHUB_PAT" ]; then
    echo "❌ GitHub PAT not found in BSM."
    echo "   Ensure a secret named 'GITHUB_PAT' exists in your BSM Project."
    exit 1
fi
export GITHUB_PAT

GITHUB_ORG="${GITHUB_ORG:-}"
_notes=""
if [ -n "${BSM_ID_BOOTSTRAP_ENV:-}" ] && [ "${BSM_ID_BOOTSTRAP_ENV}" != "00000000-0000-0000-0000-000000000000" ]; then
    _notes=$(BWS_ACCESS_TOKEN="$_bsm_token" bws secret get "$BSM_ID_BOOTSTRAP_ENV" --output json 2>/dev/null \
        | jq -r ".value" 2>/dev/null) || true
    if [ -n "${_notes:-}" ]; then
        _line=$(echo "$_notes" | grep -E '^[[:space:]]*GITHUB_ORG=' | head -1)
        [ -n "$_line" ] && GITHUB_ORG="${_line#*=}" && GITHUB_ORG=$(echo "$GITHUB_ORG" | sed "s/^['\"]//;s/['\"]$//" | tr -d "'\"" | xargs)
    fi
fi
if [ -z "$GITHUB_ORG" ]; then
    echo "❌ GITHUB_ORG not found. Add it to BSM secret BOOTSTRAP_ENV or set: sudo GITHUB_ORG=myorg ./run-bootstrap.sh"
    exit 1
fi
echo "   ✓ GitHub org: $GITHUB_ORG"

# Store allowed bootstrap config keys
BOOTSTRAP_ENV="$SECRETS_DIR/bootstrap.env"
BOOTSTRAP_ALLOWED_KEYS="GITHUB_ORG GITHUB_REPO_NAME DEPLOY_USER_PASSWORD TAILSCALE_KEY VPS_HOSTNAME PRIMARY_DOMAIN MONITOR_SUBDOMAIN TZ BACKUP_CRON_TIME MAINT_CRON_TIME FETCH_SECRETS PHASE2_MODE PROVISION_KUMA RUN_BACKUP_CONFIG ADD_APPS DEPLOY_APPS"
if [ -n "${_notes:-}" ] && echo "$_notes" | grep -q "="; then
    : > "$BOOTSTRAP_ENV"
    while IFS= read -r _line; do
        _key="${_line%%=*}"
        _key=$(echo "$_key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$_key" in
            ''|\#*) ;;
            *)
                if echo " $BOOTSTRAP_ALLOWED_KEYS " | grep -qF " ${_key} "; then
                    _val="${_line#*=}"
                    _val=$(echo "$_val" | sed 's/[[:space:]][[:space:]]*#.*$//' | sed 's/[[:space:]]*$//')
                    _val_escaped=$(printf '%s' "$_val" | sed "s/'/'\\''/g")
                    printf "%s='%s'\n" "$_key" "$_val_escaped" >> "$BOOTSTRAP_ENV"
                fi
                ;;
        esac
    done <<< "$_notes"
    unset _notes
    chmod 640 "$BOOTSTRAP_ENV"
    chown root:root "$BOOTSTRAP_ENV"
    echo "   ✓ Bootstrap config stored → $BOOTSTRAP_ENV (allowed keys only)"
else
    echo "   ⚠  BSM secret BOOTSTRAP_ENV empty or missing; Phase 2 may prompt for config."
    : > "$BOOTSTRAP_ENV"
fi

# Inject DEPLOY_USER_PASSWORD from separate DEPLOY_PASSWORD secret if found
if [ -n "${BSM_ID_DEPLOY_PASSWORD:-}" ] && [ "${BSM_ID_DEPLOY_PASSWORD}" != "00000000-0000-0000-0000-000000000000" ]; then
    _deploy_pass=$(BWS_ACCESS_TOKEN="$_bsm_token" bws secret get "$BSM_ID_DEPLOY_PASSWORD" --output json 2>/dev/null \
        | jq -r ".value" 2>/dev/null) || true
    if [ -n "$_deploy_pass" ]; then
        # Remove any existing DEPLOY_USER_PASSWORD line to avoid duplicates
        if [ -f "$BOOTSTRAP_ENV" ]; then
            sed -i '/^DEPLOY_USER_PASSWORD=/d' "$BOOTSTRAP_ENV"
        fi
        _pass_escaped=$(printf '%s' "$_deploy_pass" | sed "s/'/'\\''/g")
        printf "DEPLOY_USER_PASSWORD='%s'\n" "$_pass_escaped" >> "$BOOTSTRAP_ENV"
        echo "   ✓ Deploy password fetched from BSM and added to config."
    fi
fi

# Inject TAILSCALE_KEY from separate secret if found
if [ -n "${BSM_ID_TAILSCALE_KEY:-}" ] && [ "${BSM_ID_TAILSCALE_KEY}" != "00000000-0000-0000-0000-000000000000" ]; then
    _ts_key=$(BWS_ACCESS_TOKEN="$_bsm_token" bws secret get "$BSM_ID_TAILSCALE_KEY" --output json 2>/dev/null \
        | jq -r ".value" 2>/dev/null) || true
    if [ -n "$_ts_key" ]; then
        if [ -f "$BOOTSTRAP_ENV" ]; then
            sed -i '/^TAILSCALE_KEY=/d' "$BOOTSTRAP_ENV"
        fi
        _ts_escaped=$(printf '%s' "$_ts_key" | sed "s/'/'\\''/g")
        printf "TAILSCALE_KEY='%s'\n" "$_ts_escaped" >> "$BOOTSTRAP_ENV"
        echo "   ✓ Tailscale key fetched from BSM and added to config."
    fi
fi
chmod 640 "$BOOTSTRAP_ENV"
chown root:deploy "$BOOTSTRAP_ENV" 2>/dev/null || true
echo ""

# ─── Deploy user (needed before clone so we can chown) ──────────────────────
if ! id -u deploy &>/dev/null; then
    echo "👤 Creating deploy user..."
    useradd -m -s /bin/bash deploy
    echo "   ✓ Deploy user created (Docker group added in Phase 1)"
fi
[ -f "$BOOTSTRAP_ENV" ] && chown root:deploy "$BOOTSTRAP_ENV" 2>/dev/null || true

# ─── Clone private infra-core (PAT via GIT_ASKPASS, not in process list) ──────
_cred_token="$SECRETS_DIR/.git-token-$$"
_cred_script="$SECRETS_DIR/.git-cred-helper-$$"
cleanup_cred() {
    rm -f "$_cred_token" "$_cred_script" 2>/dev/null
    unset GIT_ASKPASS GIT_TERMINAL_PROMPT
}
trap cleanup_cred EXIT

if [ -d "$INSTALL_DIR/.git" ]; then
    echo "📦 Updating existing infra-core at $INSTALL_DIR..."
    cd "$INSTALL_DIR"
    git remote set-url origin "https://github.com/${GITHUB_ORG}/${GITHUB_REPO_NAME}.git"
    # Use credential helper for pull so PAT is not in argv
    printf '%s\n' "$GITHUB_PAT" > "$_cred_token"
    chmod 600 "$_cred_token"
    printf '#!/bin/sh\ncase "$1" in *[Pp]assword*) cat "%s" ;; *) echo "git" ;; esac\n' "$_cred_token" > "$_cred_script"
    chmod 700 "$_cred_script"
    export GIT_ASKPASS="$_cred_script"
    export GIT_TERMINAL_PROMPT=0
    if ! git pull origin "$BRANCH"; then
        echo "❌ Failed to update infra-core (git pull origin $BRANCH)."
        exit 1
    fi
    cd - > /dev/null
else
    echo "📦 Cloning private infra-core to $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR"
    printf '%s\n' "$GITHUB_PAT" > "$_cred_token"
    chmod 600 "$_cred_token"
    printf '#!/bin/sh\ncase "$1" in *[Pp]assword*) cat "%s" ;; *) echo "git" ;; esac\n' "$_cred_token" > "$_cred_script"
    chmod 700 "$_cred_script"
    export GIT_ASKPASS="$_cred_script"
    export GIT_TERMINAL_PROMPT=0
    git clone -b "$BRANCH" "https://github.com/${GITHUB_ORG}/${GITHUB_REPO_NAME}.git" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    git remote set-url origin "https://github.com/${GITHUB_ORG}/${GITHUB_REPO_NAME}.git"
    cd - > /dev/null
    echo "   ✓ Clone done (PAT via helper, not in process list); token file removed"
fi
trap - EXIT
cleanup_cred

# Security hardening: keep infra repo and privileged scripts root-owned so sudo path rules
# cannot be bypassed by editing allowed script files.
chown -R deploy:deploy "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true
find "$INSTALL_DIR" -type f -exec chmod 644 {} \; 2>/dev/null || true
find "$INSTALL_DIR/scripts" -type f -name "*.sh" -exec chmod 755 {} \; 2>/dev/null || true
echo "   ✓ infra-core ready at $INSTALL_DIR (owned by deploy; sudo-safe)"

# Write discovered IDs to bsm-ids.conf (Phase 2 will use this)
_bsm_ids_file="$INSTALL_DIR/var/bsm-ids.conf"
mkdir -p "$INSTALL_DIR/var"
{
    echo "# Generated by run-bootstrap.sh (V13)"
    [ -n "${BSM_ID_BOOTSTRAP_ENV:-}" ] && echo "BSM_ID_BOOTSTRAP_ENV=$BSM_ID_BOOTSTRAP_ENV"
    [ -n "${BSM_ID_DEPLOY_PASSWORD:-}" ] && echo "BSM_ID_DEPLOY_PASSWORD=$BSM_ID_DEPLOY_PASSWORD"
    [ -n "${BSM_ID_GITHUB_PAT:-}" ] && echo "BSM_ID_GITHUB_PAT=$BSM_ID_GITHUB_PAT"
    [ -n "${BSM_ID_TAILSCALE_KEY:-}" ] && echo "BSM_ID_TAILSCALE_KEY=$BSM_ID_TAILSCALE_KEY"
    [ -n "${BSM_ID_ORIGIN_CERT:-}" ] && echo "BSM_ID_ORIGIN_CERT=$BSM_ID_ORIGIN_CERT"
    [ -n "${BSM_ID_ORIGIN_KEY:-}" ] && echo "BSM_ID_ORIGIN_KEY=$BSM_ID_ORIGIN_KEY"
    [ -n "${BSM_ID_R2_ENDPOINT:-}" ] && echo "BSM_ID_R2_ENDPOINT=$BSM_ID_R2_ENDPOINT"
    [ -n "${BSM_ID_R2_BUCKET:-}" ] && echo "BSM_ID_R2_BUCKET=$BSM_ID_R2_BUCKET"
    [ -n "${BSM_ID_R2_ACCESS_KEY_ID:-}" ] && echo "BSM_ID_R2_ACCESS_KEY_ID=$BSM_ID_R2_ACCESS_KEY_ID"
    [ -n "${BSM_ID_R2_SECRET_ACCESS_KEY:-}" ] && echo "BSM_ID_R2_SECRET_ACCESS_KEY=$BSM_ID_R2_SECRET_ACCESS_KEY"
    [ -n "${BSM_ID_KUMA_USER:-}" ] && echo "BSM_ID_KUMA_USER=$BSM_ID_KUMA_USER"
    [ -n "${BSM_ID_KUMA_PASS:-}" ] && echo "BSM_ID_KUMA_PASS=$BSM_ID_KUMA_PASS"
    [ -n "${BSM_ID_TELEGRAM_BOT_TOKEN:-}" ] && echo "BSM_ID_TELEGRAM_BOT_TOKEN=$BSM_ID_TELEGRAM_BOT_TOKEN"
    [ -n "${BSM_ID_TELEGRAM_CHAT_ID:-}" ] && echo "BSM_ID_TELEGRAM_CHAT_ID=$BSM_ID_TELEGRAM_CHAT_ID"
    [ -n "${BSM_ID_SMTP_HOST:-}" ] && echo "BSM_ID_SMTP_HOST=$BSM_ID_SMTP_HOST"
    [ -n "${BSM_ID_SMTP_PORT:-}" ] && echo "BSM_ID_SMTP_PORT=$BSM_ID_SMTP_PORT"
    [ -n "${BSM_ID_SMTP_FROM:-}" ] && echo "BSM_ID_SMTP_FROM=$BSM_ID_SMTP_FROM"
    [ -n "${BSM_ID_SMTP_TO:-}" ] && echo "BSM_ID_SMTP_TO=$BSM_ID_SMTP_TO"
    [ -n "${BSM_ID_BACKUP_KEY:-}" ] && echo "BSM_ID_BACKUP_KEY=$BSM_ID_BACKUP_KEY"
} > "$_bsm_ids_file"
chmod 644 "$_bsm_ids_file"
echo "   ✓ BSM ID mapping auto-populated → /opt/infra/var/bsm-ids.conf"
echo ""

# ─── Run Phase 1 ─────────────────────────────────────────────────────────────
echo "🔧 Running Phase 1 (foundation, Tailscale, GitHub access, firewall)..."
echo ""
_phase1_exit=0
bash "$INSTALL_DIR/scripts/bootstrap-phase1.sh" || _phase1_exit=$?

# ─── Run Phase 2 automatically (BSM Token still active) ─────────────────────
_phase2_exit=0
if [ "$_phase1_exit" -eq 0 ]; then
    echo ""
    echo "🔧 Running Phase 2 (Caddy, secrets, apps, cron)..."
    echo ""
    # Pass BSM token to Phase 2 so it doesn't re-prompt
    export BSM_ACCESS_TOKEN="$_bsm_token"
    bash "$INSTALL_DIR/scripts/bootstrap-phase2.sh" || _phase2_exit=$?
fi

# ─── Cleanup BSM Token from memory ───────────────────────────────────────────
echo ""
echo "🔒 Clearing BSM Access Token from process memory..."
unset BSM_ACCESS_TOKEN _bsm_token 2>/dev/null || true
history -c 2>/dev/null || true
echo "   ✓ Secrets cleared from environment."
echo ""

if [ "$_phase1_exit" -ne 0 ]; then
    echo "❌ Phase 1 failed (exit code: $_phase1_exit). Phase 2 was skipped."
    exit "$_phase1_exit"
elif [ "$_phase2_exit" -ne 0 ]; then
    echo "⚠️  Phase 1 succeeded but Phase 2 failed (exit code: $_phase2_exit)."
    echo "   Fix the issue, then re-run Phase 2:"
    echo "   tailscale ssh deploy@$(hostname)"
    echo "   sudo $INSTALL_DIR/scripts/bootstrap-phase2.sh"
    exit "$_phase2_exit"
else
    echo "╔════════════════════════════════════════════╗"
    echo "║   Bootstrap Complete (Phase 1 + Phase 2)   ║"
    echo "╚════════════════════════════════════════════╝"
    echo ""
    echo "   Connect as deploy user:"
    echo "   tailscale ssh deploy@$(hostname)"
    echo ""
fi
