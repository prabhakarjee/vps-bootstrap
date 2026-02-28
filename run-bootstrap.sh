#!/bin/bash
# run-bootstrap.sh — Public entry point for VPS bootstrap when infra-core is private.
#
# This script lives in the PUBLIC repo "vps-bootstrap". It asks for Bitwarden API
# at runtime, fetches bootstrap credentials from the vault, clones the PRIVATE
# infra-core repo, and runs Phase 1. No secrets are stored in any repo.
#
# Flow:
#   1. Run this script as root (on a fresh VPS).
#   2. Provide Bitwarden API key (prompted, or set BW_CLIENTID / BW_CLIENTSECRET).
#   3. Script writes /opt/secrets/bw.env, authenticates to Bitwarden, fetches
#      GitHub PAT and GITHUB_ORG from vault (Infra GitHub PAT, Infra Bootstrap Env).
#   4. Clones private infra-core to /opt/infra, strips PAT from git remote.
#   5. Runs infra-core Phase 1 (foundation, Tailscale, GitHub access, firewall).
#   6. You then log in as deploy via Tailscale SSH and run Phase 2.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/<org>/vps-bootstrap/master/run-bootstrap.sh -o run-bootstrap.sh
#   chmod +x run-bootstrap.sh && sudo ./run-bootstrap.sh
#
# Or clone the public repo and run:
#   git clone https://github.com/<org>/vps-bootstrap.git /tmp/vps-bootstrap
#   sudo /tmp/vps-bootstrap/run-bootstrap.sh
#
# Required Bitwarden items (create before running):
#   - "Infra GitHub PAT" (Login, Password = ghp_... or github_pat_...)
#   - "Infra Bootstrap Env" (Secure Note, Notes = content including GITHUB_ORG=myorg)
#
# Optional: set BW_CLIENTID and BW_CLIENTSECRET in environment to skip prompts.

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
    read -p "Continue anyway? (y/N): " confirm 2>/dev/null || true
    [[ "${confirm:-n}" != "y" ]] && exit 1
fi
echo ""

# ─── Bitwarden API key ─────────────────────────────────────────────────────
mkdir -p "$SECRETS_DIR"
chmod 750 "$SECRETS_DIR"

if [ ! -r "$BW_ENV" ] || ! grep -qE '^BW_CLIENTID=' "$BW_ENV" 2>/dev/null || ! grep -qE '^BW_CLIENTSECRET=' "$BW_ENV" 2>/dev/null; then
    if [ -n "${BW_CLIENTID:-}" ] && [ -n "${BW_CLIENTSECRET:-}" ]; then
        echo "📝 Writing Bitwarden API key to $BW_ENV (from environment)."
        tee "$BW_ENV" > /dev/null << EOF
BW_CLIENTID=$BW_CLIENTID
BW_CLIENTSECRET=$BW_CLIENTSECRET
EOF
    else
        echo "Bitwarden API key is required so this script can fetch credentials and clone the private infra-core repo."
        echo "Get it from: Bitwarden → Settings → Security → Keys → View API key."
        echo ""
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
    echo "   ✓ $BW_ENV created"
else
    echo "   ✓ Using existing $BW_ENV"
fi
chmod 600 "$BW_ENV" 2>/dev/null || true
chown root:root "$BW_ENV" 2>/dev/null || true
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
BW_CLIENTID="$BW_CLIENTID" BW_CLIENTSECRET="$BW_CLIENTSECRET" bw login --apikey --quiet 2>/dev/null || {
    echo "❌ Bitwarden API login failed. Check credentials in $BW_ENV"
    exit 1
}
echo "   ✓ Bitwarden authenticated"
echo ""

# ─── Fetch GitHub PAT and GITHUB_ORG from Bitwarden ─────────────────────────
GITHUB_TOKEN=""
GITHUB_TOKEN=$(bw get password "Infra GitHub PAT" 2>/dev/null) || true
if [ -z "$GITHUB_TOKEN" ]; then
    echo "❌ Bitwarden item 'Infra GitHub PAT' not found or empty."
    echo "   Add a Login item: name 'Infra GitHub PAT', Password = ghp_... or github_pat_..."
    exit 1
fi

GITHUB_ORG="${GITHUB_ORG:-}"
if [ -z "$GITHUB_ORG" ]; then
    _notes=""
    _notes=$(bw get notes "Infra Bootstrap Env" 2>/dev/null) || true
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
echo ""

# ─── Deploy user (needed before clone so we can chown) ──────────────────────
if ! id -u deploy &>/dev/null; then
    echo "👤 Creating deploy user..."
    useradd -m -s /bin/bash deploy
    echo "   ✓ Deploy user created (Docker group added in Phase 1)"
fi

# ─── Clone private infra-core ──────────────────────────────────────────────
REPO_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_ORG}/${GITHUB_REPO_NAME}.git"

if [ -d "$INSTALL_DIR/.git" ]; then
    echo "📦 Updating existing infra-core at $INSTALL_DIR..."
    cd "$INSTALL_DIR"
    git remote set-url origin "https://github.com/${GITHUB_ORG}/${GITHUB_REPO_NAME}.git"
    git pull origin "$BRANCH" || true
    cd - > /dev/null
else
    echo "📦 Cloning private infra-core to $INSTALL_DIR..."
    mkdir -p "$INSTALL_DIR"
    git clone -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    git remote set-url origin "https://github.com/${GITHUB_ORG}/${GITHUB_REPO_NAME}.git"
    cd - > /dev/null
    echo "   ✓ Token stripped from git remote (not stored on disk)"
fi

chown -R deploy:deploy "$INSTALL_DIR"
find "$INSTALL_DIR/scripts" -type f -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
echo "   ✓ infra-core ready at $INSTALL_DIR"
echo ""

# ─── Run Phase 1 ─────────────────────────────────────────────────────────────
echo "🔧 Running Phase 1 (foundation, Tailscale, GitHub access, firewall)..."
echo ""
exec "$INSTALL_DIR/scripts/bootstrap-phase1.sh"
