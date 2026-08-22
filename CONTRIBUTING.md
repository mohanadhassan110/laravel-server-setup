# Contributing to laravel-server-setup

Thanks for considering a contribution! This project automates server
provisioning, so **correctness and safety matter more than features**. A bug
here can lock someone out of their server - please review your changes with
that in mind.

## How to report a problem

1. Open a [GitHub Issue](../../issues) and include:
   - Ubuntu version (`lsb_release -a`)
   - Which step/script failed
   - The exact error output (redact passwords!)
2. Search existing issues first to avoid duplicates.

## How to submit changes

1. Fork the repository and create a feature branch:

   ```bash
   git checkout -b feat/my-awesome-feature
   ```

2. Make your change. Keep scripts:
   - **Idempotent** - running the same script twice must never break anything.
   - **Fail fast** - use `set -euo pipefail` and `die` with clear messages.
   - **Consistent** - reuse helpers from `lib/helpers.sh`; follow the existing
     header-comment style (Arabic summary header, English inline comments).

3. Lint before committing:

   ```bash
   shellcheck -x --severity=style install.sh lib/*.sh scripts/*.sh
   ```

4. Test on a throwaway VM. The fastest options:

   ```bash
   # Multipass (recommended)
   multipass launch 22.04 --name lss-test --cpus 2 --memory 2G --disk 20G
   multipass exec lss-test -- sudo bash -c "apt-get update && apt-get install -y git"
   # ...push your branch to the VM and run install.sh inside it

   # Or Vagrant/VirtualBox with bento/ubuntu-22.04
   ```

5. Open a Pull Request describing *what* changed and *why*.
   One logical change per PR keeps reviews fast.

## Commit message convention

We follow [Conventional Commits](https://www.conventionalcommits.org/):

```
feat(scripts): add fail2ban installation step
fix(ssl): retry issuance when DNS has not propagated yet
docs: expand firewall section in README
chore: bump shellcheck action to v4
```

Allowed types: `feat`, `fix`, `docs`, `chore`, `refactor`, `ci`, `test`.

## Code standards checklist

- [ ] `set -euo pipefail` at the top of every script
- [ ] Passes `shellcheck -x --severity=style` with zero warnings
- [ ] All variables quoted; no unvalidated input interpolated into configs
- [ ] Secrets never echoed in plain text unless explicitly confirmed
- [ ] New user-facing strings match the tone of existing messages

## Licensing

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).
