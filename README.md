# opa — 1Password CLI multi-account wrapper

`opa` is a thin Bash wrapper around the [1Password CLI](https://developer.1password.com/docs/cli/) (`op`) that adds inline account selection to `op://` secret references. It is a transparent drop-in: every `op` subcommand works as normal, and refs that don't use the extended syntax pass through untouched.

## The problem

The standard `op` CLI resolves secret references in the form:

```text
op://vault/item/field
```

When you have multiple 1Password accounts, the only way to target a specific one is to pass `--account` on the command line. This makes it impossible to mix references from different accounts in a single `.env` file, and it means every invocation has to know which account to use out of band.

## The solution

`opa` extends the URI scheme with an optional account prefix using either `@` or `:` as the separator:

```text
op://account@vault/item/field   ← preferred
op://account:vault/item/field   ← also accepted
op://vault/item/field           ← standard, passed through unchanged
```

When `opa` sees an extended reference, it strips the account prefix and passes `--account <account>` to the real `op` binary. All other arguments are forwarded as-is.

## Requirements

- [1Password CLI](https://developer.1password.com/docs/cli/) (`op`) v2+
- Bash 3.2+ (compatible with the system Bash on macOS)

## Installation

```bash
bash install.sh
```

The installer will:

1. Auto-detect the real `op` binary and bake its path into the installed script
2. Ask where to install `opa` (default: `/usr/local/bin`)
3. Optionally wire it as `op` via symlink or shell alias

All prompts can be skipped by setting environment variables:

| Variable | Description | Default |
| --- | --- | --- |
| `OP_REAL` | Path to the real `op` binary | auto-detected |
| `INSTALL_DIR` | Where to install `opa` | `/usr/local/bin` |
| `WIRE_AS_OP` | How to expose as `op`: `symlink`, `alias`, or `none` | prompted |
| `OP_LINK_DIR` | Where to create the `op` symlink (symlink mode only) | prompted |
| `RC_FILE` | RC file to add the alias to (alias mode only) | auto-detected |

Example non-interactive install:

```bash
INSTALL_DIR=~/.local/bin WIRE_AS_OP=none bash install.sh
```

### Wiring as `op`

If you want `op` to transparently become `opa`:

- **symlink** — creates `op -> opa` in a directory of your choice (`~/bin`, `~/.local/bin`, or a custom path). If a real `op` binary already lives there it is moved to `op.real` and `opa` is updated to point at it automatically.
- **alias** — appends `alias op='opa'` to your shell RC file (`~/.zshrc`, `~/.bashrc`, or a custom path).
- **none** — use `opa` directly and set up `op` yourself.

### Finding the real `op` binary

`opa` locates the real `op` binary in this order:

1. `$OP_REAL` environment variable
2. The path baked in by the installer
3. `/opt/homebrew/bin/op` (Apple Silicon Homebrew default)
4. `/usr/local/bin/op` (Intel Homebrew / manual install default)

You can override the path at any time without reinstalling:

```bash
export OP_REAL=/path/to/op
```

## Usage

All standard `op` commands work exactly as before:

```bash
opa signin
opa whoami
opa item list
```

### Inline account references

Specify the account inside the `op://` URI using `@` (preferred) or `:`:

```bash
# read a secret from the 'work' account
opa read op://work@Engineering/GitHubToken/password

# run a process with secrets injected from multiple accounts
opa run --env-file .env -- ./myapp
```

### Multi-account `.env` files

The main benefit: a single `.env` file can reference secrets from different accounts.

```bash
# .env
GITHUB_TOKEN=op://work@Engineering/GitHubToken/password
PERSONAL_KEY=op://personal:Private/SSHKey/private_key
SHARED_SECRET=op://SharedVault/DBPassword/password   # no account prefix — uses default
```

```bash
opa run --env-file .env -- ./myapp
```

`opa` rewrites the env file in a temporary copy before passing it to `op`, so the real file is never modified.

### Constraints

- All extended refs in a single invocation must use the **same account**. Mixing accounts across arguments or within a single env file is an error — split them into separate commands.
- An extended ref in an argument and one in an env file must also agree on the account.

## Without the installer

`opa` can be used directly without installing:

```bash
./opa read op://work@Engineering/GitHubToken/password
```

If the real `op` binary is not in one of the default locations, set `OP_REAL`:

```bash
export OP_REAL=/opt/homebrew/bin/op
./opa run --env-file .env -- ./myapp
```
