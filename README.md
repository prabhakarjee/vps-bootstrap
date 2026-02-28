# vps-bootstrap

The **public bootstrap entrypoint** for igniting a fresh VPS and safely bridging to the private `infra-core` repository.

> [!NOTE] 
> **Are you in an active outage?**
> Refer to the `infra-core` repository's [🚨 2 AM EMERGENCY RUNBOOK](https://github.com/prabhakarjee/infra-core/blob/master/docs/EMERGENCY-RUNBOOK.md) for recovery steps immediately.

## What is this?
This repository contains a singular, foolproof script (`run-bootstrap.sh`). It is designed to be purely publicly accessible so you can curl it directly onto a brand new server without handling SSH keys first.

**It does exactly 5 things automatically:**
1. Securely queries your Bitwarden vault via its API for a temporary run.
2. Extracts your GitHub Personal Access Token and your specific domain/environment configurations.
3. Authenticates and Clones your private `infra-core` ecosystem into `/opt/infra`.
4. Executes the Phase 1 hardening sequence (Tailscale SSH enforcement, Basic Dependencies, UFW Firewall).
5. Prompts to seamlessly transition into Phase 2 Application automation (via `bootstrap-phase2.sh`).

*Zero secrets are ever persisted to the disk after Phase 1 terminates.*

---

## 🚀 Quick Start (Production Pipeline)

### Step 1: Execute on a fresh VPS as `root`
*(Replace `<org>` with `prabhakarjee` or your github username)*
```bash
curl -sSL https://raw.githubusercontent.com/<org>/vps-bootstrap/master/run-bootstrap.sh -o run-bootstrap.sh
chmod +x run-bootstrap.sh
sudo ./run-bootstrap.sh
```

### Step 2: Handoff Phase
The script will cleanly prompt you to start Phase 2 interactively:
> `Do you want to automatically start Phase 2 now? [Y/n]`

Accept this, and the bootstrap will fetch the remaining Caddy proxy code, install Uptime Kuma, and install the global `infra` CLI tool on the server. 

### Step 3: Day-to-Day Operations
You are now live. Connect to your server anytime via Tailscale SSH.
```bash
tailscale ssh deploy@<vps-hostname>

# Check the server health immediately
infra status
```

---

## What to Read Next
- [Infrastructure Gap Rating `INFRA-RATING.md`](INFRA-RATING.md) - A frank score on scalability vs security.
- [`BIRD-EYE-VIEW.md`](BIRD-EYE-VIEW.md) - How `vps-bootstrap` and `infra-core` intertwine safely.
- [Production Readiness Checklist](PRODUCTION-CHECKLIST.md) - Final validation before traffic ingress.
