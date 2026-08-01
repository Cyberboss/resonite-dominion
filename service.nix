inputs@{ config, lib, pkgs, ... }:

let
  manifest = (builtins.fromTOML (builtins.readFile ./Cargo.toml)).package;
  service-name = manifest.name;
  cfg = config.services.${service-name};

  package = pkgs.rustPlatform.buildRustPackage rec {
    pname = service-name;
    version = manifest.version;

    src = ./.;
    cargoLock.lockFile = ./Cargo.lock;
    meta.mainProgram = service-name;
  };

  launch-script = pkgs.writeShellScriptBin "launch-script" ''
    set -euxo pipefail
    exec ${lib.getExe package} --port ${
      builtins.toString cfg.port
    } --shutdown-seconds ${builtins.toString cfg.shutdown-seconds} daemon
  '';
in {
  options.services.${service-name} = {
    enable = lib.mkEnableOption "";
    shutdown-seconds = lib.mkOption {
      type = lib.types.ints.u32;
      description = ''
        The duration in seconds to wait before termination if any shutdown handlers are registered
      '';
      default = 600;
    };

    username = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = service-name;
      description = ''
        The name of the user used to execute ${service-name}.
      '';
    };

    groupname = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = service-name;
      description = ''
        The name of group the user used to execute ${service-name} will belong to.
      '';
    };

    port = lib.mkOption {
      type = lib.types.ints.u16;
      description = ''
        The port to use.
      '';
      default = 24444;
    };

    headless-service = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = ''
        The name of the resonite-headless service ending in ".service".
      '';
      default = "resonite-headless.service";
    };
  };

  config = lib.mkIf cfg.enable {
    users = {
      groups."${cfg.groupname}" = { };
      users."${cfg.username}" = {
        isSystemUser = true;
        createHome = true;
        group = cfg.groupname;
      };
    };

    systemd.services = {
      "${service-name}" = {
        description = service-name;
        serviceConfig = {
          User = cfg.username;
          Type = "exec";
          ExecStart = "${launch-script}/bin/launch-script";
          TimeoutStopSec =
            "${(builtins.toString (cfg.shutdown-seconds + 60))}s";
          Restart = "always";
          KillSignal = "SIGINT";
        };
        bindsTo = [ cfg.headless-service ];
        after = [ cfg.headless-service ];
        wantedBy = [ cfg.headless-service ];
      };
    };
  };
}
