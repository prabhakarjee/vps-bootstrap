# Infrastructure Bird's Eye View

## Overview

The automated infrastructure relies on a dual-repository architecture designed to provision, secure, and operate a single-VPS production environment. The design strictly adheres to a **three-source model**, ensuring the VPS itself is ephemeral and completely reproducible:
1. **Code**: Version-controlled in GitHub.
2. **Secrets**: Managed externally via Bitwarden.
3. **Data**: Backed up and restored via Cloudflare R2.

This architecture splits the provisioning process into a public entry point and a private core payload.

## Repository Roles

### 1. `vps-bootstrap` (Public Entry Point)
This is a lightweight, public repository designed to handle **Phase 1** of the server lifecycle. It acts as the "ignition" sequence for a fresh server.
- **Core Script**: `run-bootstrap.sh`
- **Function**: 
  - Authenticates securely with Bitwarden using a temporary API key (or falls back to secure manual interactive prompts if Bitwarden is unavailable).
  - Fetches essential bootstrap configuration (e.g., GitHub Personal Access Token, Org names).
  - Clones the private `infra-core` repository to `/opt/infra`.
  - Executes the Initial `bootstrap-phase1.sh` script from the core repo.
  - Clears all temporary credentials from the server to prevent lingering secret exposures.
  - Automatically prompts and executes a seamless handoff to Phase 2 operations.

### 2. `infra-core` (Private Payload & Operations)
This private repository contains the actual operational payload, configuration templates, and day-two operation scripts.
- **Core scripts**: `bootstrap-phase1.sh`, `bootstrap-phase2.sh`, and `scripts/app-lifecycle/*`.
- **Function**:
  - **Phase 1**: Sets up foundational dependencies, configures the `deploy` user, locks down SSH by enforcing Tailscale, and enables UFW firewall restricted to Cloudflare IPs.
  - **Phase 2**: Bootstraps the runtime environment (fetches runtime secrets, starts Caddy reverse proxy, launches Uptime Kuma for monitoring, configures cron jobs for backups to R2, and registers applications).
  - **Day-Two Operations**: Handles app deployments, backups, health reporting, and maintenance routines.

## System Architecture

- **Ingress**: All external traffic flows through Cloudflare proxy into Caddy.
- **Access**: Operator access is exclusively through Tailscale SSH (no direct port 22 access).
- **Security Scope**: Root executes the initial bootstrap; day-two operations run as a restricted `deploy` user with heavily scoped `sudo` privileges over specific operations scripts.
- **State Management**: The VPS relies on predictable Git states and remote R2 backups, ensuring smooth disaster recovery (DR) rebuilds.
