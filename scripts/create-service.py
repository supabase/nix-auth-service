#!/usr/bin/env python3
"""Interactive script to generate a system-manager systemd service skeleton."""

import json
import re
import sys

CONFIG_FILE = ".service-config.json"
SERVICE_FILE = "service.nix"


def prompt(message):
    """Prompt user for input, repeat until non-empty."""
    while True:
        value = input(f"{message}: ").strip()
        if value:
            return value
        print("  Value cannot be empty.")


def validate_service_name(name):
    """Return True if name is lowercase letters, digits, and hyphens only, starting with a letter."""
    return bool(re.match(r"^[a-z][a-z0-9-]*$", name))


def write_service_nix(name):
    """Write the service.nix skeleton pre-filled with the service name."""
    content = f"""{{ pkgs, ... }}:
{{
  systemd.services.{name} = {{
    enable = true;
    description = "{name}";
    wantedBy = [ "system-manager.target" ];
    serviceConfig = {{
      Type = "simple";
      # ExecStart = "${{pkgs.{name}}}/bin/{name}";
      Restart = "on-failure";
      # User = "{name}";
    }};
    environment = {{
      # LOG_LEVEL = "info";
    }};
  }};
}}
"""
    with open(SERVICE_FILE, "w") as f:
        f.write(content)


def write_service_config(name):
    """Persist the service name to .service-config.json."""
    config = {"serviceName": name}
    with open(CONFIG_FILE, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")


def print_wiring_snippet(name):
    """Print instructions for wiring the service into a system-manager config."""
    print(f"""
{SERVICE_FILE} created for service '{name}'.

To activate with system-manager, add this to your machine's system.nix:

  inputs.nix-skel-service.url = "path:/path/to/this/repo";

  system-manager.lib.makeSystemConfig {{
    modules = [ (import "${{inputs.nix-skel-service}}/{SERVICE_FILE}") ];
  }};

Fill in the ExecStart and any other options in {SERVICE_FILE} before activating.
""")


def main():
    if len(sys.argv) < 2 or sys.argv[1] != "service":
        print("Usage: create-service.py service")
        print("Only 'service' is supported.")
        sys.exit(1)

    print("=== Nix Service Skeleton Generator ===\n")

    # 1. Prompt for service name
    while True:
        name = prompt("Service name (e.g. my-service)")
        if validate_service_name(name):
            break
        print("  Invalid name. Use lowercase letters, digits, and hyphens only.")
        print("  Must start with a letter (e.g. my-service, auth, pg-meta).")

    # 2. Write outputs
    write_service_config(name)
    print(f"  Wrote {CONFIG_FILE}")

    write_service_nix(name)
    print(f"  Wrote {SERVICE_FILE}")

    # 3. Print wiring instructions
    print_wiring_snippet(name)


if __name__ == "__main__":
    main()
