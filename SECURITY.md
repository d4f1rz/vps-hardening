# Security Policy

## Supported Versions

| Version | Supported |
|---------|-----------|
| `master` (latest) | ✅ |
| Older commits | ❌ |

Only the latest version on the `master` branch receives security fixes.
Always use the script via the canonical URL to get the most up-to-date version:
```bash
curl -fsSL https://raw.githubusercontent.com/d4f1rz/vps-hardening/master/vps_hardening.sh | sudo bash
```

---

## Reporting a Vulnerability

If you discover a security vulnerability in this script, **please do not open a public Issue**.

Instead, report it privately via one of the following:

- **GitHub Private Vulnerability Reporting** — use the [Security tab](https://github.com/d4f1rz/vps-hardening/security/advisories/new) of this repository
- **Email** — contact the maintainer directly (see profile)

Please include:
- A description of the vulnerability
- Steps to reproduce or a proof-of-concept
- Potential impact (e.g. privilege escalation, credential exposure, RCE)
- Affected environment (Ubuntu/Debian version, script version/commit)

You can expect an acknowledgment within **72 hours** and a resolution or status update within **7 days**.

---

## Scope

The following are considered in-scope vulnerabilities:

- **Privilege escalation** — the script runs as root; any logic that could be abused to escalate further or persist as root after rollback
- **Credential exposure** — private keys, passwords, or passphrases written to world-readable locations or leaked to logs
- **Command injection** — unsanitized user input passed to shell commands
- **Insecure defaults** — configurations that weaken security rather than harden it (e.g. overly permissive UFW rules, weak SSH settings)
- **Rollback/uninstall leaving system in insecure state** — e.g. open ports, password auth re-enabled without warning
- **Supply chain** — if the canonical download URL is compromised or the script fetches external dependencies insecurely

Out of scope:
- Issues with the underlying OS (Ubuntu/Debian) or third-party tools (UFW, Fail2ban, OpenSSH)
- Vulnerabilities requiring physical access to the server
- Issues in forks of this repository

---

## Security Considerations for Users

This script executes with **root privileges** and makes persistent changes to your system. Before running it in production:

1. **Review the source** — always read [`vps_hardening.sh`](./vps_hardening.sh) before piping to `bash`
2. **Use `--dry-run` first** — simulates all steps without applying changes
3. **Save the final report** — it contains your SSH key, port, and credentials; store it securely
4. **Test on a non-critical server** — especially before deploying to production
5. **Keep a console/out-of-band access** — in case SSH becomes inaccessible after hardening

> ⚠️ Running scripts via `curl | sudo bash` from the internet is inherently risky. Verify the SHA256 checksum of the script if possible, or clone the repository and run it locally.

---

## License

This project is licensed under the [MIT License](./LICENSE).
Security researchers are welcome to audit and report findings in good faith.
