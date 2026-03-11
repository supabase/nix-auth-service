# nix-auth-service

Nix flake that packages [Supabase Auth](https://github.com/supabase/auth) (gotrue) and provides a system-manager service module for deployment in supabase/postgres.

## What's Here

- **`nix/packages/`** — `buildGoModule` package for the `auth` binary, driven by `.package-config.json`
- **`service.nix`** — NixOS/system-manager module defining the `gotrue` and `gotrue-optimize` systemd services, system user, tmpfiles, and sysctl tuning; mapped from the ansible tasks in supabase/postgres
- **CI** — GitHub Actions: nix-eval + nix-build across x86_64-linux, aarch64-linux, aarch64-darwin
- **Pre-commit hooks** — actionlint + treefmt (nixfmt, deadnix)
- **Pinned nixpkgs** — follows `supabase/postgres` nixpkgs

## Current Package

| Field        | Value                         |
|--------------|-------------------------------|
| Package name | `auth`                        |
| Upstream     | `github.com/supabase/auth`    |
| Version      | `v2.187.0`                    |

## Quick Start

See [docs/GETTING-STARTED.md](docs/GETTING-STARTED.md) for how to build, update to a new release, and wire `service.nix` into deployment.
