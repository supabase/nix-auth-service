# Getting Started

Maintenance guide for the `nix-auth-service` flake — building the auth package, updating to a new release, and wiring `service.nix` into deployment.

## Prerequisites

### Install Nix

Create `nix.conf`:

```
allowed-users = *
always-allow-substitutes = true
auto-optimise-store = false
build-users-group = nixbld
builders-use-substitutes = true
cores = 0
experimental-features = nix-command flakes
max-jobs = auto
netrc-file =
require-sigs = true
substituters = https://cache.nixos.org
trusted-public-keys = cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=
trusted-substituters =
trusted-users = YOUR_USERNAME root
extra-sandbox-paths =
extra-substituters =
```

Replace `YOUR_USERNAME` with your actual username, then install:

    curl -L https://releases.nixos.org/nix/nix-2.33.2/install | \
      sh -s -- --daemon --yes --nix-extra-conf-file ./nix.conf

Log out and back in, then verify:

    nix --version

## Development Shell

    nix develop

Drops you into a shell with `just`, `treefmt`, and pre-commit hooks installed. Available commands:

| Command         | Description                          |
|-----------------|--------------------------------------|
| `package go`    | Update the auth package to a new ref |
| `fmt`           | Format all Nix files                 |
| `check`         | Run all flake checks                 |
| `lint`          | Run pre-commit hooks on all files    |

## Building the Current Package

    nix build .#auth

The binary will be at `./result/bin/auth`.

## Updating to a New Release

When a new version of `supabase/auth` is tagged, update `.package-config.json` by running:

    just package go

You will be prompted for:

- **Package name** — accept the default (`auth`)
- **GitHub URL** — accept the default (`github.com/supabase/auth`)
- **Git tag or commit** — enter the new tag (e.g. `v2.188.0`) or a commit hash

The script will:

1. Validate the repository and ref exist on GitHub
2. Compute the source hash (`sha256`)
3. Compute the Go module dependency hash (`vendorHash`)
4. Write `.package-config.json` with the new values
5. Run `nix build .#auth` to verify the result

Commit the updated `.package-config.json` and open a PR.

## service.nix

`service.nix` is a NixOS / system-manager module that defines everything needed to run the auth service on a Supabase Postgres host. It was mapped from the ansible tasks in pg-oriole-latest and covers:

- `systemd.services.gotrue` — the main auth service
- `systemd.services.gotrue-optimize` — oneshot that generates `gotrue.generated.env` via `supabase-admin-api`
- `users.users.gotrue` / `users.groups.gotrue` — dedicated system user
- `systemd.tmpfiles.rules` — `/opt/gotrue`, `/etc/auth.d`, `/etc/gotrue`
- `systemd.sysctl` — TCP keepalive, socket, and port range tuning

### Config reload

The service uses signal-based config reloading (SIGUSR1). Filesystem-notify reload can be disabled for qemu/VM environments via the `qemu_mode` argument:

```nix
# in your system config
_module.args.qemu_mode = true;   # disable inotify-based reload
```

### Wiring into supabase/postgres

See the `NEXT STEPS` block at the bottom of `service.nix` for the full integration instructions. In summary:

1. **Expose as a NixOS module** in this flake:

   ```nix
   flake.nixosModules.auth = import ./service.nix;
   ```

2. **Add inputs** in `supabase/postgres` `flake.nix`:

   ```nix
   nix-auth-service.url = "github:supabase/nix-auth-service";
   nix-auth-service.inputs.nixpkgs.follows = "nixpkgs";
   ```

3. **Compose a system config** using system-manager:

   ```nix
   flake.systemConfigs.prod = system-manager.lib.makeSystemConfig {
     modules = [
       inputs.nix-auth-service.nixosModules.auth
       ({ ... }: {
         _module.args.qemu_mode = false;
         _module.args.authPackage =
           inputs.nix-auth-service.packages.${system}.auth;
       })
     ];
   };
   ```

4. **Replace ansible binary-download and service-file tasks** with a single system-manager activation call.

## CI

Two GitHub Actions workflows run on every push:

- **nix-eval.yml** — evaluates the flake and generates the build matrix
- **nix-build.yml** — builds `auth` and runs checks on x86_64-linux, aarch64-linux, aarch64-darwin

### Optional: binary cache

To push build artifacts to an S3-based Nix binary cache, set these repository secrets:

- `DEV_AWS_ROLE` — AWS IAM role ARN for cache access
- `NIX_SIGN_SECRET_KEY` — Nix signing key for the binary cache

Without them, builds still run but outputs are not cached remotely.

### Runner requirements

- **x86_64-linux** — Blacksmith ephemeral runners with sticky disk cache
- **aarch64-linux** — Blacksmith ephemeral ARM runners with sticky disk cache
- **aarch64-darwin** — GitHub-hosted macOS runners

## Troubleshooting

### `just package go` fails at "Validating..."

The GitHub URL or git ref is wrong. Check:
- URL must be `github.com/supabase/auth`
- The tag or commit must exist in the upstream repository

### `just package go` fails at "Computing vendorHash..."

The source fetched correctly but the Go build failed. Common causes:
- CGO dependency (not supported by `buildGoModule` without extra config)
- Missing system dependency introduced in the new version

Check the build output for details. `.package-config.json` has been partially saved — re-run `just package go` to retry.

### Build fails after scaffold completes

Run `nix build .#auth -L` for verbose output. If upstream force-pushed a tag and hashes changed, re-run `just package go` with the same ref to recompute.
