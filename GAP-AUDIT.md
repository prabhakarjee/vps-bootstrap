# Infrastructure Audit & Gap Analysis

Based on an architectural review of the `vps-bootstrap` and `infra-core` repositories, the system demonstrates high maturity in secret management and network security but has several operational gaps that should be addressed as it scales.

## Identified Gaps

### 1. Automation and CI/CD Gaps
- **Lack of Script Validation** (✅ **RESOLVED**): GitHub Actions with `shellcheck` have been added to automatically validate all Bash scripts on push/PR, ensuring strict bash hygiene.
- **Manual Phase 2 Execution** (✅ **RESOLVED**): Phase 1 now auto-prompts to hand off to `deploy` and automatically start Phase 2 execution, bridging the gap between provisioning and runtime launch.

### 2. Single Point of Failure (Bitwarden)
- **Hard Dependency on SaaS** (✅ **RESOLVED**): While Bitwarden remains the primary secret source, a secure manual interactive fallback feature has been added. If Bitwarden is down, the operator can manually inject the `GITHUB_ORG`, `GITHUB_TOKEN`, and `PRIMARY_DOMAIN` to proceed with bootstrap.

### 3. Sudo Governance & Privilege Drift
- **Linux Ownership Reliance**: Security relies heavily on ensuring `/opt/infra/scripts` remain owned by `root:root` and unmodifiable by the `deploy` user. If an intermediate script artificially alters these permissions, the `deploy` user could escalate privileges by modifying a sudo-whitelisted script.
- **Recommendation**: Introduce a cron-based automated integrity checker that continuously verifies the hashes or permissions of all sudo-whitelisted `/opt/infra` scripts.

### 4. Limited Scalability by Design
- **Single-VPS Focus**: The design is optimized for a monolithic/single-VPS deployment. While excellent for smaller footprints, migrating to a multi-node or highly available (HA) setup would require a complete paradigm shift (e.g., Kubernetes, Nomad, or Ansible Swarms). There's no innate load-balancing or shared state orchestration between two nodes.

### 5. Day-Two Portability Gaps
- **Debian/Ubuntu Specifics**: Tools like `apt` and tightly coupled OS-release checks tie the architecture explicitly to Debian-derivatives. While not a massive risk, it restricts usage on RHEL/AlmaLinux derivatives if required in the future.

### 6. Testing of Apps Lifecycle
- **App Deployment Rollbacks** (✅ **RESOLVED**): `deploy-app.sh` now features a 10-second stability check with automatic rollback to the previous git commit state if the new container crashes on startup, ensuring zero downtime for malformed deployments.
