# vps-bootstrap Production Checklist

Use this checklist before running Phase 1 on a production VPS.

## 1. Access and Identity

- [ ] Dedicated GitHub deploy-bot account exists.
- [ ] Fine-grained PAT is read-only and scoped only to required repositories.
- [ ] Tailscale tailnet policy allows operator and deploy access.
- [ ] VPS provider root console access is available for break-glass.

## 2. Bitwarden Readiness

- [ ] `Infra GitHub PAT` exists and is current.
- [ ] `Infra Bootstrap Env` exists with required keys.
- [ ] `Infra Tailscale Auth Key` exists and is reusable.
- [ ] Bitwarden API key (`BW_CLIENTID`, `BW_CLIENTSECRET`) is tested.

## 3. Bootstrap Configuration Hygiene

- [ ] `Infra Bootstrap Env` contains bootstrap keys only.
- [ ] No tenant DB passwords, billing keys, or app runtime secrets are included.
- [ ] `VPS_HOSTNAME` is set to a stable, unique host name.

## 4. VPS Preconditions

- [ ] OS is Ubuntu 22.04/24.04 or Debian.
- [ ] Root can run `apt`, `curl`, and `git`.
- [ ] Outbound network access is open for GitHub, Bitwarden, Tailscale, Docker package repos.

## 5. Phase 1 Acceptance Criteria

- [ ] `run-bootstrap.sh` exits with success.
- [ ] `/opt/infra` exists and is root-owned.
- [ ] deploy user can log in via `tailscale ssh deploy@<hostname>`.
- [ ] UFW is enabled and policy is applied.
- [ ] Bitwarden session is logged out and `/opt/secrets/bw.env` is removed.

## 6. Handoff to infra-core Phase 2

- [ ] Operator can run: `sudo /opt/infra/scripts/bootstrap-phase2.sh` as deploy.
- [ ] Domain and Cloudflare plan are ready.
- [ ] Phase 2 secret items (origin cert/key, R2, Kuma, app env) are prepared.

## 7. Rollback Policy

If Phase 1 fails:
- keep console access open
- capture terminal logs
- fix root cause and rerun script
- do not hand-edit infra scripts on VPS unless required for emergency recovery

## 8. Change Management

- [ ] Pin a release tag/commit for production bootstrap usage.
- [ ] Document which script version was used per environment.
- [ ] Require peer review before changing `run-bootstrap.sh`.
