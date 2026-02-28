# vps-bootstrap

Public bootstrap entrypoint for private `infra-core` deployments.

This repository contains one script (`run-bootstrap.sh`) that performs Phase 1 on a fresh VPS:
- collects Bitwarden API credentials for this run
- fetches bootstrap values and GitHub PAT from Bitwarden
- clones private `infra-core` to `/opt/infra`
- runs `infra-core/scripts/bootstrap-phase1.sh`
- logs out of Bitwarden and removes `bw.env`

## Who This Is For

Use this repo when:
- `infra-core` is private
- you are bootstrapping a new VPS or rebuilding from scratch
- you want a reproducible, script-first Phase 1

## Production Intent

This repo is production-safe when used with:
- dedicated deploy-bot GitHub account + fine-grained PAT (read-only)
- Bitwarden as the only secret source
- Tailscale SSH access for operator login
- Cloudflare-proxied traffic (Phase 2 + firewall policy)

See [PRODUCTION-CHECKLIST.md](PRODUCTION-CHECKLIST.md) before first production rollout.

## Required Bitwarden Items

Exact names are required:
- `Infra GitHub PAT` (Login, Password field)
- `Infra Bootstrap Env` (Secure Note, KEY=VALUE lines)
- `Infra Tailscale Auth Key` (Login, Password field)

Minimum `Infra Bootstrap Env` values:
- `GITHUB_ORG`
- `DEPLOY_USER_PASSWORD`
- `PRIMARY_DOMAIN`
- `MONITOR_SUBDOMAIN`
- `VPS_HOSTNAME` (recommended)

## Quick Start

Run on the VPS as root:

```bash
curl -sSL https://raw.githubusercontent.com/<org>/vps-bootstrap/master/run-bootstrap.sh -o run-bootstrap.sh
chmod +x run-bootstrap.sh
sudo ./run-bootstrap.sh
```

Alternative:

```bash
git clone https://github.com/<org>/vps-bootstrap.git /tmp/vps-bootstrap
sudo /tmp/vps-bootstrap/run-bootstrap.sh
```

## What Success Looks Like

Phase 1 is complete when:
- `/opt/infra` exists and contains the private repo
- deploy login path is shown as `tailscale ssh deploy@<hostname>`
- firewall is enabled
- script prints "Phase 1 Complete"

Then continue with Phase 2:

```bash
tailscale ssh deploy@<vps-hostname>
sudo /opt/infra/scripts/bootstrap-phase2.sh
```

## Security Guarantees

`run-bootstrap.sh` is designed to:
- avoid storing Bitwarden API credentials after Phase 1
- avoid storing GitHub PAT in git remote URL
- keep bootstrap secrets scoped to allowed keys only
- leave `infra-core` as root-owned code on VPS

## Common Failure Cases

1. Bitwarden login fails
- verify `BW_CLIENTID` and `BW_CLIENTSECRET`
- rotate API key and retry

2. Private repo clone fails
- verify `Infra GitHub PAT` scope and repo access
- verify `GITHUB_ORG` in `Infra Bootstrap Env`

3. Tailscale auth not available
- ensure `Infra Tailscale Auth Key` exists
- if omitted, script falls back to interactive Tailscale auth

4. Phase 1 script fails midway
- review output
- fix root cause
- re-run `sudo ./run-bootstrap.sh` (idempotent flow)

## Repository Contract

- This repo should remain small and public.
- No runtime app secrets must be added here.
- All non-bootstrap operations belong in `infra-core`.

Replace `<org>` with your GitHub org or username.
