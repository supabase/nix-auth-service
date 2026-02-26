# Package a service for Nix
package language:
    python3 scripts/package-go.py {{language}}

# Create a skeleton service definition for system-manager
create target:
    python3 scripts/create-service.py {{target}}
