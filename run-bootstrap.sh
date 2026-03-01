#!/bin/bash
# run-bootstrap.sh — Public entry point for VPS bootstrap when infra-core is private.
#
# This script lives in the PUBLIC repo "vps-bootstrap". It asks for Bitwarden
# access temporarily, fetches bootstrap credentials and stores them, runs Phase 1,
# then logs out of Bitwarden and removes the API key from disk. No Bitwarden
# credentials persist on the VPS after bootstrap.
#
# Flow:
#   1. Root login → run this script as root.
#   2. Script asks for BSM Access Token (temporary; or set BSM_ACCESS_TOKEN in env).
#   3. Script fetches "BOOTSTRAP_ENV" via BSM and stores it to /opt/secrets/bootstrap.env; fetches GitHub PAT and GITHUB_ORG for clone.
#   4. Clones private infra-core to /opt/infra, strips PAT from git remote.
#   5. Runs Phase 1 (foundation, Tailscale, GitHub access via deploy-bot PAT, firewall).
#   6. Runs Phase 2 as the deploy user without requiring any further interactive prompts.
#
# GitHub: Use a Dedicated Deploy Bot account + one Fine-Grained PAT (Contents: Read
# for infra-core and app repos). Store the PAT in Bitwarden Secrets Manager mapped to BSM_ID_GITHUB_PAT.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/<org>/vps-bootstrap/master/run-bootstrap.sh -o run-bootstrap.sh
#   chmod +x run-bootstrap.sh && sudo ./run-bootstrap.sh
#
# Required Bitwarden items: "Infra GitHub PAT", "Infra Bootstrap Env" (with GITHUB_ORG), "Infra Tailscale Auth Key".

set -euo pipefail

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

# Install bws CLI if not present (needed to fetch GitHub PAT + bootstrap env below)
if ! command -v bws &>/dev/null; then
    echo "📦 Installing bws CLI..."
    _bws_url=$(curl -s "https://api.github.com/repos/bitwarden/sdk-sm/releases/latest" \
        | grep browser_download_url | grep "x86_64-unknown-linux-gnu.zip" | head -1 | cut -d'"' -f4 2>/dev/null) || true
    if [ -n "$_bws_url" ]; then
        curl -sL "$_bws_url" -o /tmp/bws.zip
        unzip -o -q /tmp/bws.zip bws -d /usr/local/bin/ 2>/dev/null || true
        chmod +x /usr/local/bin/bws 2>/dev/null || true
        rm -f /tmp/bws.zip
        echo "   ✓ bws installed"
    else
        echo "   ⚠  Could not install bws — install manually from https://github.com/bitwarden/sdk-sm/releases"
    fi
    unset _bws_url
fi


# ─── Dependencies ───────────────────────────────────────────────────────────
echo "📦 Ensuring git and curl..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl > /dev/null 2>&1

echo "   ✓ Dependencies ready"
echo ""

# ─── Fetch GitHub PAT and bootstrap env from BSM ─────────────────────────────
if ! command -v bws &>/dev/null; then
    echo "❌ bws CLI not found. Check install step above."
    exit 1
fi
_bsm_token=$(tr -d '[:space:]' < "$BSM_TOKEN_FILE" 2>/dev/null)

GITHUB_TOKEN=""
if [ -n "${BSM_ID_GITHUB_PAT:-}" ] && [ "${BSM_ID_GITHUB_PAT}" != "00000000-0000-0000-0000-000000000000" ]; then
    GITHUB_TOKEN=$(BWS_ACCESS_TOKEN="$_bsm_token" bws secret get "$BSM_ID_GITHUB_PAT" --output json 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('value',''), end='')" 2>/dev/null) || true
fi
if [ -z "$GITHUB_TOKEN" ]; then
    echo "❌ GitHub PAT not found in BSM (BSM_ID_GITHUB_PAT)."
    echo "   Ensure bsm-ids.conf has BSM_ID_GITHUB_PAT set and the secret exists in BSM."
    exit 1
fi

GITHUB_ORG="${GITHUB_ORG:-}"
if [ -z "$GITHUB_ORG" ] && [ -n "${BSM_ID_BOOTSTRAP_ENV:-}" ] && [ "${BSM_ID_BOOTSTRAP_ENV}" != "00000000-0000-0000-0000-000000000000" ]; then
    _notes=$(BWS_ACCESS_TOKEN="$_bsm_token" bws secret get "$BSM_ID_BOOTSTRAP_ENV" --output json 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('value',''), end='')" 2>/dev/null) || true
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
BOOTSTRAP_ALLOWED_KEYS="GITHUB_ORG GITHUB_REPO_NAME DEPLOY_USER_PASSWORD VPS_HOSTNAME PRIMARY_DOMAIN MONITOR_SUBDOMAIN TZ BACKUP_CRON_TIME MAINT_CRON_TIME FETCH_SECRETS PHASE2_MODE PROVISION_KUMA RUN_BACKUP_CONFIG ADD_APPS DEPLOY_APPS"
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
fi
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
    printf '%s\n' "$GITHUB_TOKEN" > "$_cred_token"
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
    printf '%s\n' "$GITHUB_TOKEN" > "$_cred_token"
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
