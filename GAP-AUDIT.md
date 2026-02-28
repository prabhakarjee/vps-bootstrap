# Infrastructure Audit & Gap Analysis

Based on an architectural review of the `vps-bootstrap` and `infra-core` repositories, the system demonstrates high maturity in secret management and network security but has several operational gaps that should be addressed as it scales.

## Identified Gaps

### 1. Automation and CI/CD Gaps
- **Lack of Script Validation**: Bash scripts form the backbone of this infrastructure, yet there is no automated CI pipeline in GitHub to run `shellcheck`, syntax validation (`bash -n`), or automated integration tests natively.
- **Manual Phase 2 Execution**: While Phase 1 is automated, Phase 2 currently requires an operator to log in via Tailscale SSH and run `bootstrap-phase2.sh` manually. Full automation of the handover would reduce operator toil.

### 2. Single Point of Failure (Bitwarden)
- **Hard Dependency on SaaS**: The entire bootstrap process requires immediate, real-time access to the Bitwarden API. If Bitwarden is experiencing an outage, new server provisioning is completely blocked. 
- **Recommendation**: Define a break-glass "offline secret payload" mechanism or secondary vault fallback for emergency disaster recovery operations.

### 3. Sudo Governance & Privilege Drift
- **Linux Ownership Reliance**: Security relies heavily on ensuring `/opt/infra/scripts` remain owned by `root:root` and unmodifiable by the `deploy` user. If an intermediate script artificially alters these permissions, the `deploy` user could escalate privileges by modifying a sudo-whitelisted script.
- **Recommendation**: Introduce a cron-based automated integrity checker that continuously verifies the hashes or permissions of all sudo-whitelisted `/opt/infra` scripts.

### 4. Limited Scalability by Design
- **Single-VPS Focus**: The design is optimized for a monolithic/single-VPS deployment. While excellent for smaller footprints, migrating to a multi-node or highly available (HA) setup would require a complete paradigm shift (e.g., Kubernetes, Nomad, or Ansible Swarms). There's no innate load-balancing or shared state orchestration between two nodes.

### 5. Day-Two Portability Gaps
- **Debian/Ubuntu Specifics**: Tools like `apt` and tightly coupled OS-release checks tie the architecture explicitly to Debian-derivatives. While not a massive risk, it restricts usage on RHEL/AlmaLinux derivatives if required in the future.

### 6. Testing of Apps Lifecycle
- The application deployment scripts (`deploy-with-setup.sh`) rely heavily on Docker. The gap lies in lacking automated rollback capabilities if an app container fails to boot after `docker compose up`. Health checks are delegated to Uptime Kuma *after* the deployment succeeds, leaving a small window where a broken deployment remains live until manually reverted.
