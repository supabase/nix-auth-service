# Mapped from ansible/tasks/setup-gotrue.yml and ansible/tasks/setup-system.yml
# in pg-oriole-latest. The following ansible operations were moved here:
#
#   systemd.services.gotrue
#     <- ansible/files/gotrue.service.j2
#        (task: "gotrue - create service file" in setup-gotrue.yml)
#
#   systemd.services.gotrue-optimize
#     <- ansible/files/gotrue-optimizations.service.j2
#        (task: "gotrue - create optimizations file" in setup-gotrue.yml)
#
#   users.users.gotrue / users.groups.gotrue
#     <- task: "Gotrue - system user" in setup-gotrue.yml
#
#   systemd.tmpfiles.rules (/opt/gotrue, /etc/auth.d, /etc/gotrue)
#     <- task: "gotrue - create /opt/gotrue and /etc/auth.d" in setup-gotrue.yml
#
#   systemd.sysctl (net.ipv4.tcp_keepalive_time, tcp_keepalive_intvl,
#                   ip_local_reserved_ports, vm.panic_on_oom, kernel.panic,
#                   net.core.somaxconn, net.ipv4.ip_local_port_range)
#     <- tasks: "Set net.ipv4.*" / "Set vm.*" / "configure system" in setup-system.yml
#
# Intentionally kept in ansible:
#   - UFW port 9122 (metrics)       <- setup-gotrue.yml
#   - pg_ident.conf gotrue mapping  <- postgresql_config/pg_ident.conf.j2
#
#
# system-manager writes unit files into the systemd unit path just like Ansible does;
# the resulting files are plain systemd units. systemd doesn't know or care which tool deployed them.
# qemu_mode controls whether filesystem notify-based config reloading is
# disabled (true = qemu/vm, false = bare metal default).
# Wire this up via specialArgs or _module.args in your flake.
{
  qemu_mode ? false,
  ...
}:
{
  systemd.services.gotrue = {
    description = "Gotrue";

    # Avoid starting gotrue while cloud-init is running. It makes a lot of changes
    # and I would like to rule out side effects of it running concurrently along
    # side services.
    after = [
      "cloud-init.service"
      # Given the fact that auth uses SO_REUSEADDR, I want to rule out capabilities
      # being modified between restarts early in boot.
      "apparmor.service"
      # We want sysctl's to be applied
      "systemd-sysctl.service"
      # UFW is modified by cloud init, but started non-blocking, so configuration
      # could be in-flight while gotrue is starting.
      "ufw.service"
      # We need networking & resolution, auth uses the Go DNS resolver (not libc)
      # so it's possible `localhost` resolution could be unstable early in startup.
      "network-online.target"
      "systemd-resolved.service"
      # Auth server can't start unless postgres is online.
      "postgresql.service"
    ];

    wants = [
      "cloud-init.target"
      "network-online.target"
      "systemd-resolved.service"
      "postgresql.service"
    ];
    # system-manager itself creates a system-manager.target unit that
    #is WantedBy=multi-user.target. By making gotrue WantedBy=system-manager.target,
    # we ensure that gotrue is started as part of the normal boot process,
    # but only after the system-manager.target is reached.
    # This allows us to have better control over the startup order
    # and ensures that gotrue is started at the appropriate time during the boot sequence.
    # This approach can coexist with services that are not yet defined in nix and managed
    # by system-manager, as long as they are properly ordered with respect to system-manager.target
    wantedBy = [ "system-manager.target" ];

    unitConfig = {
      # Setting these to 0 with Restart=always and RestartSec=3 will prevent
      # gotrue from being marked as failed when the default burst limit is
      # exceeded (e.g. due to salt/cloud-init explicit restarts or recovering
      # services within the --before chain).
      StartLimitIntervalSec = 0;
      StartLimitBurst = 0;
    };

    serviceConfig = {
      Type = "exec";
      WorkingDirectory = "/opt/gotrue";

      # Both v2 & v3 need a config-dir for reloading support.
      ExecStart = "/opt/gotrue/gotrue --config-dir /etc/auth.d";
      # Both v2 & v3 support reloading via signals, on linux this is SIGUSR1.
      ExecReload = "/bin/kill -10 $MAINPID";

      User = "gotrue";
      Restart = "always";
      RestartSec = 3;

      MemoryAccounting = true;
      MemoryMax = "50%";

      # Historical env file locations. /etc/auth.d will override when present.
      # The leading '-' means systemd will not fail if the file is missing.
      EnvironmentFile = [
        "-/etc/gotrue.generated.env"
        "/etc/gotrue.env"
        "-/etc/gotrue.overrides.env"
      ];

      Slice = "services.slice";
    };

    environment = {
      # Both v2 & v3 support reloading via signals, on linux this is SIGUSR1.
      GOTRUE_RELOADING_SIGNAL_ENABLED = "true";
      GOTRUE_RELOADING_SIGNAL_NUMBER = "10";

      # Both v2 & v3 disable the poller. While gotrue sets it to off by default
      # we defensively set it to false here.
      GOTRUE_RELOADING_POLLER_ENABLED = "false";

      # Determines how much idle time must pass before triggering a reload. This
      # ensures only 1 reload operation occurs during a burst of config updates.
      GOTRUE_RELOADING_GRACE_PERIOD_INTERVAL = "2s";

      # v3 does not use filesystem notifications for config reloads (qemu/vm).
      # v2 currently relies on notify support, so we enable it until both v2/v3
      # have migrated to strictly use signals across all projects.
      GOTRUE_RELOADING_NOTIFY_ENABLED = if qemu_mode then "false" else "true";
    };
  };

  users.users.gotrue = {
    isSystemUser = true;
    group = "gotrue";
  };

  users.groups.gotrue = { };

  systemd.tmpfiles.rules = [
    # mode/owner match setup-gotrue.yml: mode 0775, owner gotrue
    "d /opt/gotrue 0775 gotrue gotrue - -"
    "d /etc/auth.d 0775 gotrue gotrue - -"
    # gotrue-optimize writes /etc/gotrue/gotrue.generated.env; directory must exist
    "d /etc/gotrue 0775 gotrue gotrue - -"
  ];

  # Sysctl parameters from setup-system.yml
  systemd.sysctl = {
    # TCP keepalive tuning
    "net.ipv4.tcp_keepalive_time" = 1800;
    "net.ipv4.tcp_keepalive_intvl" = 60;
    # postgres_exporter on 9187, adminapi on 8085 — prevent ephemeral port collisions
    "net.ipv4.ip_local_reserved_ports" = "9187,8085";
    # Restart on OOM after 10s
    "vm.panic_on_oom" = 1;
    "kernel.panic" = 10;
    # Socket and port range tuning
    "net.core.somaxconn" = 16834;
    "net.ipv4.ip_local_port_range" = "1025 65000";
  };

  systemd.services.gotrue-optimize = {
    description = "GoTrue (Auth) optimizations";

    wantedBy = [ "system-manager.target" ];

    serviceConfig = {
      Type = "oneshot";
      # Failures here must not block gotrue startup; exit 0 is intentional.
      ExecStart = "/bin/bash -c \"/opt/supabase-admin-api optimize auth --destination-config-file-path /etc/gotrue/gotrue.generated.env ; exit 0\"";
      ExecStartPost = "/bin/bash -c \"cp -a /etc/gotrue/gotrue.generated.env /etc/auth.d/20_generated.env ; exit 0\"";
      User = "postgrest";
    };
  };
}
# -----------------------------------------------------------------------------
# NEXT STEPS TO WIRE THIS INTO DEPLOYMENT
# -----------------------------------------------------------------------------
#
# 1. Expose this file as a NixOS module output in this flake (nix-auth-service):
#
#      flake.nixosModules.auth = import ./service.nix;
#
#    Also thread the built package into ExecStart so ansible no longer
#    downloads the binary:
#
#      ExecStart = "${authPackage}/bin/auth --config-dir /etc/auth.d";
#
#    where authPackage is passed via _module.args from the system config.
#
# 2. In supabase/postgres (pg-oriole-latest) flake.nix:
#
#    a. Add inputs:
#
#         system-manager.url = "github:numtide/system-manager";
#         nix-auth-service.url = "github:supabase/auth";
#         nix-auth-service.inputs.nixpkgs.follows = "nixpkgs";
#
#    b. Add a systemConfigs output in nix/hosts.nix (or a new nix/system-configs.nix):
#
#         flake.systemConfigs.prod = system-manager.lib.makeSystemConfig {
#           modules = [
#             inputs.nix-auth-service.nixosModules.auth
#             # inputs.nix-postgrest-service.nixosModules.postgrest
#             # inputs.nix-adminapi-service.nixosModules.adminapi
#             ({ ... }: {
#               _module.args.qemu_mode = false;
#               _module.args.authPackage =
#                 inputs.nix-auth-service.packages.${system}.auth;
#             })
#           ];
#         };
#
# 3. In ansible (setup-gotrue.yml or a new task), replace the binary download
#    and service file deployment tasks with a single system-manager activation:
#
#      - name: auth - activate system-manager config
#        ansible.builtin.command: >
#          nix run github:numtide/system-manager --
#            switch --flake github:supabase/postgres#prod
#        become: false
#
#    This replaces:
#      - "gotrue - download commit archive"
#      - "gotrue - create service file"
#      - "gotrue - create optimizations file"
#      - "gotrue - reload systemd"
#      - "Gotrue - system user"
#      - "gotrue - create /opt/gotrue and /etc/auth.d"
#      - all sysctl tasks in setup-system.yml
#
# -----------------------------------------------------------------------------
