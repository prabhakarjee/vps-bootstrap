# vps-bootstrap

**Public** repo containing the single script used to bootstrap a VPS when the infrastructure repo (**infra-core**) is **private**.

No secrets are stored in this repo. The script asks for Bitwarden API credentials at runtime, fetches the minimal bootstrap credentials from the vault, clones the private infra-core repo, and runs Phase 1.

## Strategy

```
Public repo (vps-bootstrap)
    ↓
Script asks for Bitwarden API at runtime (or reads BW_CLIENTID / BW_CLIENTSECRET)
    ↓
Authenticate to Bitwarden → fetch Infra GitHub PAT + GITHUB_ORG (from Infra Bootstrap Env)
    ↓
Clone private infra-core to /opt/infra (PAT stripped from remote after clone)
    ↓
Run infra-core Phase 1 (foundation, Tailscale, GitHub access, firewall)
    ↓
Operator logs in as deploy via Tailscale SSH and runs Phase 2 from infra-core
```

## Prerequisites

- **VPS:** Ubuntu 22.04/24.04 (or Debian), root access.
- **Bitwarden:** Account with these items created (exact names, case-sensitive):
  - **Infra GitHub PAT** — Login item, Password = `ghp_...` or `github_pat_...` (read access to the private infra-core repo).
  - **Infra Bootstrap Env** — Secure Note, Notes = content that includes `GITHUB_ORG=myorg` (your GitHub org or username).

Before Phase 2 you will need the rest of the secrets listed in infra-core’s [OPERATIONS.md](https://github.com/<org>/infra-core/blob/master/docs/OPERATIONS.md) (origin cert, R2, etc.).

## Quick start

On a fresh VPS as root:

**Option A — one-liner (curl):**

```bash
curl -sSL https://raw.githubusercontent.com/<org>/vps-bootstrap/master/run-bootstrap.sh -o run-bootstrap.sh
chmod +x run-bootstrap.sh && sudo ./run-bootstrap.sh
```

**Option B — clone this public repo then run:**

```bash
git clone https://github.com/<org>/vps-bootstrap.git /tmp/vps-bootstrap
sudo /tmp/vps-bootstrap/run-bootstrap.sh
```

When prompted, enter your Bitwarden API key (client_id and client_secret from Bitwarden → Settings → Security → Keys → View API key). Or set them in the environment to skip prompts:

```bash
sudo BW_CLIENTID=user.xxx BW_CLIENTSECRET=secret ./run-bootstrap.sh
```

The script will:

1. Create `/opt/secrets/bw.env` with the Bitwarden API key (so infra-core Phase 1 can use it).
2. Install git, curl, and Bitwarden CLI (`bw`) if needed.
3. Log in to Bitwarden and fetch **Infra GitHub PAT** and **GITHUB_ORG** from **Infra Bootstrap Env**.
4. Clone the private **infra-core** repo to `/opt/infra` and strip the PAT from the git remote.
5. Run **Phase 1** from infra-core (foundation, Tailscale, GitHub access, firewall).

After Phase 1 completes, log in as the deploy user via Tailscale SSH and run Phase 2:

```bash
tailscale ssh deploy@<vps-hostname>
sudo /opt/infra/scripts/bootstrap-phase2.sh
```

## Repo relationship

| Repo           | Visibility | Role |
|----------------|------------|------|
| **vps-bootstrap** | Public     | Single script: Bitwarden API → clone infra-core → run Phase 1. No secrets. |
| **infra-core**    | Private    | Full platform: Phase 1/2, Caddy, apps, backup, operations. See [infra-core](https://github.com/<org>/infra-core) and its `docs/OPERATIONS.md`. |

System design and tech stack are documented in **sys-blueprint**; operations and runbooks live in **infra-core**.

## Placeholders

Replace `<org>` with your GitHub organisation or username in the URLs above.
