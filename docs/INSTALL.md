# Installing the Kazoo 4.4 stack

Supported: **Debian 11 (bullseye)** and **Debian 12 (bookworm)**, **amd64** and **arm64**.

Pick the codename matching your OS: `bullseye` for Debian 11, `bookworm` for
Debian 12. The snippet below auto-detects it from `/etc/os-release`.

```bash
curl -fsSL https://cloudpbx.github.io/openkazoo-kazoo4-builder/pubkey.asc \
  | sudo tee /usr/share/keyrings/openkazoo.asc > /dev/null

. /etc/os-release   # sets $VERSION_CODENAME (bullseye or bookworm)
echo "deb [signed-by=/usr/share/keyrings/openkazoo.asc] \
https://cloudpbx.github.io/openkazoo-kazoo4-builder ${VERSION_CODENAME} main" \
  | sudo tee /etc/apt/sources.list.d/openkazoo.list

sudo apt-get update
sudo apt-get install -y kazoo freeswitch kamailio
```

`erlang` (OTP 26.2.5.20) is pulled in automatically as a dependency of `kazoo`.

## What gets installed

| Package | Contents | Path |
|---|---|---|
| `erlang` | Erlang/OTP 26.2.5.20 (built via kerl) | `/usr/local/lib/erlang` |
| `kazoo` | Kazoo 4.4 release (ERTS not bundled — uses the `erlang` package) | `/opt/kazoo` |
| `freeswitch` | FreeSWITCH 1.10.9 + `mod_kazoo` | `/usr/bin/freeswitch`, `/usr/lib/freeswitch/mod` |
| `kamailio` | Kamailio 5.8.8 (db_mysql db_postgres tls kazoo rabbitmq) | `/usr/sbin/kamailio` |

## Notes

- These are community builds; there is no commercial support.
- Service orchestration (systemd units, config, clustering) is handled by your
  deployment tooling (e.g. `kazoo-deploy`), not by these packages.
