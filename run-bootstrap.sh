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
#   2. Script asks for Bitwarden API key (temporary; or set BW_CLIENTID/BW_CLIENTSECRET in env).
#   3. Script authenticates to Bitwarden, fetches "Infra Bootstrap Env" and stores
#      it to /opt/secrets/bootstrap.env; fetches GitHub PAT and GITHUB_ORG for clone.
#   4. Clones private infra-core to /opt/infra, strips PAT from git remote.
#   5. Writes bw.env temporarily so Phase 1 can use it (Tailscale, GitHub PAT for deploy user).
#   6. Runs Phase 1 (foundation, Tailscale, GitHub access via deploy-bot PAT, firewall).
#   7. After Phase 1: full logout (bw logout), unset BW_*, history -c, and removes /opt/secrets/bw.env.
#   8. You log in as deploy via Tailscale SSH and run Phase 2.
#
# GitHub: Use a Dedicated Deploy Bot account + one Fine-Grained PAT (Contents: Read
# for infra-core and app repos). Store the PAT in Bitwarden as "Infra GitHub PAT".
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

# ─── Bitwarden API key (temporary; removed after Phase 1) ───────────────────
mkdir -p "$SECRETS_DIR"
chmod 750 "$SECRETS_DIR"

echo "Bitwarden access is used only for this run. The script will log out and remove the API key from disk after Phase 1."
echo "Get API key from: Bitwarden → Settings → Security → Keys → View API key."
echo ""

if [ -n "${BW_CLIENTID:-}" ] && [ -n "${BW_CLIENTSECRET:-}" ]; then
    echo "📝 Using Bitwarden API key from environment."
    tee "$BW_ENV" > /dev/null << EOF
BW_CLIENTID=$BW_CLIENTID
BW_CLIENTSECRET=$BW_CLIENTSECRET
EOF
else
    [ -t 0 ] && read -r -p "Enter BW_CLIENTID: " BW_CLIENTID
    [ -t 0 ] && read -r -s -p "Enter BW_CLIENTSECRET: " BW_CLIENTSECRET && echo ""
    if [ -z "${BW_CLIENTID:-}" ] || [ -z "${BW_CLIENTSECRET:-}" ]; then
        echo "❌ Set BW_CLIENTID and BW_CLIENTSECRET (environment or prompt)."
        exit 1
    fi
    tee "$BW_ENV" > /dev/null << EOF
BW_CLIENTID=$BW_CLIENTID
BW_CLIENTSECRET=$BW_CLIENTSECRET
EOF
fi
chmod 600 "$BW_ENV"
chown root:root "$BW_ENV"
echo "   ✓ Bitwarden API key will be used for this run only (removed after Phase 1)"
echo ""

# ─── Dependencies ───────────────────────────────────────────────────────────
echo "📦 Ensuring git, curl, and Bitwarden CLI..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl > /dev/null 2>&1

if ! command -v bw &>/dev/null; then
    if command -v snap &>/dev/null; then
        snap install bw 2>/dev/null || { echo "❌ snap install bw failed"; exit 1; }
    else
        echo "❌ Install Bitwarden CLI: snap install bw  OR  npm i -g @bitwarden/cli"
        exit 1
    fi
fi
echo "   ✓ Dependencies ready"
echo ""

# ─── Load bw.env and authenticate ───────────────────────────────────────────
set +x
set -a
# shellcheck source=/dev/null
. "$BW_ENV" 2>/dev/null || true
set +a
[ -n "${BW_CLIENTID:-}" ] && export BW_CLIENTID
[ -n "${BW_CLIENTSECRET:-}" ] && export BW_CLIENTSECRET
[[ $- == *x* ]] && set -x

if [ -z "${BW_CLIENTID:-}" ] || [ -z "${BW_CLIENTSECRET:-}" ]; then
    echo "❌ BW_CLIENTID and BW_CLIENTSECRET must be set in $BW_ENV"
    exit 1
fi

echo "🔐 Authenticating to Bitwarden..."
# Logout first in case a previous run left the CLI in a logged-in state
bw logout 2>/dev/null || true
BW_CLIENTID="$BW_CLIENTID" BW_CLIENTSECRET="$BW_CLIENTSECRET" bw login --apikey --quiet 2>/dev/null || {
    echo "❌ Bitwarden API login failed. Check credentials in $BW_ENV"
    exit 1
}
echo "   ✓ Bitwarden authenticated"

_status=$(bw status 2>/dev/null | grep -o '"status":"[^"]*"' | cut -d'"' -f4 2>/dev/null || echo "unauthenticated")
if [ "$_status" = "locked" ]; then
    echo ""
    echo "   🔐 Bitwarden vault locked. Enter master password to unlock:"
    set +x
    BW_SESSION=$(bw unlock --raw 2>/dev/null </dev/tty) || {
        echo "❌ Bitwarden unlock failed."
        exit 1
    }
    export BW_SESSION
    [[ $- == *x* ]] && set -x
    echo "   ✓ Bitwarden unlocked for this session"
elif [ "$_status" = "unlocked" ]; then
    echo "   ✓ Bitwarden already unlocked"
else
    echo "❌ Bitwarden status check failed: $_status"
    exit 1
fi
echo ""

# ─── Fetch GitHub PAT and GITHUB_ORG from Bitwarden ─────────────────────────
GITHUB_TOKEN=""
GITHUB_TOKEN=$(bw get password "Infra GitHub PAT" --session "$BW_SESSION" 2>/dev/null) || true
if [ -z "$GITHUB_TOKEN" ]; then
    echo "❌ Bitwarden item 'Infra GitHub PAT' not found or empty."
    echo "   Add a Login item: name 'Infra GitHub PAT', Password = ghp_... or github_pat_..."
    exit 1
fi

GITHUB_ORG="${GITHUB_ORG:-}"
if [ -z "$GITHUB_ORG" ]; then
    _notes=""
    _notes=$(bw get notes "Infra Bootstrap Env" --session "$BW_SESSION" 2>/dev/null) || true
    if [ -n "$_notes" ]; then
        _line=$(echo "$_notes" | grep -E '^[[:space:]]*GITHUB_ORG=' | head -1)
        if [ -n "$_line" ]; then
            GITHUB_ORG="${_line#*=}"
            GITHUB_ORG="${GITHUB_ORG%%#*}"
            GITHUB_ORG=$(echo "$GITHUB_ORG" | tr -d '"' | tr -d "'" | xargs)
        fi
    fi
fi
if [ -z "$GITHUB_ORG" ]; then
    echo "❌ GITHUB_ORG not set. Add GITHUB_ORG=myorg to Bitwarden Secure Note 'Infra Bootstrap Env', or run: sudo GITHUB_ORG=myorg ./run-bootstrap.sh"
    exit 1
fi
echo "   ✓ GitHub org: $GITHUB_ORG"

# Store only allowed bootstrap config (never tenant DB, Supabase, billing, etc.)
BOOTSTRAP_ENV="$SECRETS_DIR/bootstrap.env"
BOOTSTRAP_ALLOWED_KEYS="GITHUB_ORG GITHUB_REPO_NAME DEPLOY_USER_PASSWORD VPS_HOSTNAME PRIMARY_DOMAIN MONITOR_SUBDOMAIN TZ BACKUP_CRON_TIME MAINT_CRON_TIME FETCH_SECRETS PHASE2_MODE PROVISION_KUMA RUN_BACKUP_CONFIG ADD_APPS DEPLOY_APPS"
_notes=""
_notes=$(bw get notes "Infra Bootstrap Env" --session "$BW_SESSION" 2>/dev/null) || true
if [ -n "$_notes" ]; then
    : > "$BOOTSTRAP_ENV"
    while IFS= read -r _line; do
        _key="${_line%%=*}"
        _key=$(echo "$_key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$_key" in
            ''|\#*) ;;
            *)
                if echo " $BOOTSTRAP_ALLOWED_KEYS " | grep -qF " ${_key} "; then
                    printf '%s\n' "$_line" >> "$BOOTSTRAP_ENV"
                fi
                ;;
        esac
    done <<< "$_notes"
    chmod 640 "$BOOTSTRAP_ENV"
    chown root:root "$BOOTSTRAP_ENV"
    echo "   ✓ Bootstrap config stored → $BOOTSTRAP_ENV (allowed keys only; no app/tenant secrets)"
else
    echo "   ⚠  Bitwarden item 'Infra Bootstrap Env' empty or missing; Phase 2 may prompt for config."
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
chown -R root:root "$INSTALL_DIR"
find "$INSTALL_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true
find "$INSTALL_DIR" -type f -exec chmod 644 {} \; 2>/dev/null || true
find "$INSTALL_DIR/scripts" -type f -name "*.sh" -exec chmod 755 {} \; 2>/dev/null || true
[ -f "$INSTALL_DIR/bootstrap.sh" ] && chmod 755 "$INSTALL_DIR/bootstrap.sh" 2>/dev/null || true
echo "   ✓ infra-core ready at $INSTALL_DIR (root-owned scripts; sudo-safe)"
echo ""

# ─── Run Phase 1 ─────────────────────────────────────────────────────────────
echo "🔧 Running Phase 1 (foundation, Tailscale, GitHub access, firewall)..."
echo ""
_phase1_exit=0
bash "$INSTALL_DIR/scripts/bootstrap-phase1.sh" || _phase1_exit=$?

# ─── Full Bitwarden logout and remove API key from disk ──────────────────────
echo ""
echo "🔒 Logging out of Bitwarden and removing API key from disk..."
if command -v bw &>/dev/null; then
    bw logout >/dev/null 2>&1 || true
fi
unset BW_SESSION BW_CLIENTID BW_CLIENTSECRET 2>/dev/null || true
history -c 2>/dev/null || true
rm -f "$BW_ENV"
echo "   ✓ Bitwarden logged out (session cleared); $BW_ENV removed (no Bitwarden credentials left on VPS)."
echo ""
if [ "$_phase1_exit" -eq 0 ]; then
    echo "Next: log in as deploy via Tailscale SSH and run Phase 2:"
    echo "   tailscale ssh deploy@\$(hostname)"
    echo "   sudo $INSTALL_DIR/scripts/bootstrap-phase2.sh"
    echo ""
fi

exit "$_phase1_exit"
