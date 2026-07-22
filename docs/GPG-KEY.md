# Signing key setup

CI signs packages with a GPG key stored in repository secrets. The public key
is published automatically as `pubkey.asc` at the apt-repo site root.

## One-time setup (maintainer)

1. Generate a signing key (ed25519). Omit a passphrase for unattended CI, or
   set one and add it as `GPG_PASSPHRASE` below:
   ```bash
   gpg --batch --quick-generate-key "openkazoo build <build@cloudpbx.example>" ed25519 sign 2y
   ```
2. Find the fingerprint and export the private key (ASCII-armored):
   ```bash
   gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/{print $10; exit}'
   gpg --armor --export-secret-keys <FPR>
   ```
3. In the repo: **Settings → Secrets and variables → Actions → New repository
   secret**:
   - `GPG_PRIVATE_KEY` — the full ASCII-armored private key block.
   - `GPG_PASSPHRASE` — only if the key has a passphrase.

## Local signing

For local `make sign` without CI secrets, point `GNUPGHOME` at a keyring that
holds a signing-capable secret key:

```bash
GNUPGHOME=/path/to/keyring make sign
```

`scripts/sign.sh` prefers `$GPG_PRIVATE_KEY` (CI) and falls back to `$GNUPGHOME`.
