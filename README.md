# vps-bootstrap

**Public** repo with a single script to bootstrap a VPS when **infra-core** is private. No secrets in this repo. The script asks for **Bitwarden access temporarily**, fetches bootstrap credentials and stores them, runs Phase 1, then **logs out of Bitwarden and removes the API key** from disk.

## Flow

1. **Root login** on the VPS.
2. **Run the script** (curl or clone this repo).
3. **Script asks for Bitwarden API key** (temporary; not stored on VPS after Phase 1).
4. Script **authenticates to Bitwarden**, fetches **Infra Bootstrap Env** and **stores it** to `/opt/secrets/bootstrap.env`, fetches **Infra GitHub PAT** and **GITHUB_ORG**.
5. Script **clones private infra-core** to `/opt/infra` (PAT stripped from remote).
6. Script runs **Phase 1** (foundation, Tailscale, **GitHub via deploy-bot PAT**, firewall).
7. Script **logs out of Bitwarden and removes `/opt/secrets/bw.env`** — no Bitwarden credentials left on VPS.
8. **You** log in as **deploy** via Tailscale SSH and run **Phase 2** (see infra-core [OPERATIONS.md](https://github.com/<org>/infra-core/blob/master/docs/OPERATIONS.md)).

## GitHub: Dedicated Deploy Bot + Fine-Grained PAT

Use a **Dedicated Deploy Bot** account (e.g. `myorg-deploy`) and one **Fine-Grained PAT**: **Repository access** = infra-core and the app repos the VPS needs; **Permissions** = **Contents: Read-only**. Store the PAT in Bitwarden as **Infra GitHub PAT** (Login item, Password field). One credential for all clones; clear audit trail.

## Bitwarden: login once, fetch, logout

The script uses Bitwarden only for this run: you provide the API key when prompted; the script fetches credentials and stores bootstrap.env; after Phase 1 it runs `bw logout` and removes `bw.env`. For **Phase 2 no-prompt** (fetch-secrets, add-app, etc.), create `/opt/secrets/bw.env` on the VPS before running Phase 2 (see infra-core OPERATIONS.md § No-prompt operation).

## Prerequisites

- **VPS:** Ubuntu 22.04/24.04 (or Debian), root access.
- **Bitwarden** items (exact names): **Infra GitHub PAT**, **Infra Bootstrap Env** (with `GITHUB_ORG=myorg`), **Infra Tailscale Auth Key**.
- Phase 2 needs more items (origin cert, R2, etc.); see infra-core [OPERATIONS.md](https://github.com/<org>/infra-core/blob/master/docs/OPERATIONS.md).

## Quick start

**As root on the VPS:**

```bash
curl -sSL https://raw.githubusercontent.com/<org>/vps-bootstrap/master/run-bootstrap.sh -o run-bootstrap.sh
chmod +x run-bootstrap.sh && sudo ./run-bootstrap.sh
```

Or clone and run:

```bash
git clone https://github.com/<org>/vps-bootstrap.git /tmp/vps-bootstrap
sudo /tmp/vps-bootstrap/run-bootstrap.sh
```

When prompted, enter your Bitwarden API key (Settings → Security → Keys → View API key). Or set `BW_CLIENTID` and `BW_CLIENTSECRET` in the environment to skip the prompt.

After Phase 1, log in as deploy and run Phase 2:

```bash
tailscale ssh deploy@<vps-hostname>
sudo /opt/infra/scripts/bootstrap-phase2.sh
```

For Phase 2 to fetch secrets from Bitwarden without prompts, create `/opt/secrets/bw.env` before Phase 2.

## Repo relationship

| Repo           | Visibility | Role |
|----------------|------------|------|
| **vps-bootstrap** | Public     | Single script: temporary Bitwarden → fetch and store bootstrap credentials → clone infra-core → Phase 1 → logout and remove bw.env. |
| **infra-core**    | Private    | Full platform: Phase 1/2, Caddy, apps, backup. See [infra-core](https://github.com/<org>/infra-core) and `docs/OPERATIONS.md`. |

Replace `<org>` with your GitHub org or username.
