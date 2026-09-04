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

  reason-file-path = cfg.update-reason-file-path;
  launch-script = pkgs.writeShellScriptBin "launch-script.sh" ''
    set -euxo pipefail
    exec ${lib.getExe package} --port ${
      builtins.toString cfg.port
    } --shutdown-seconds ${
      builtins.toString cfg.shutdown-seconds
    } --reason-file-path "${reason-file-path}" daemon
  '';
  pre-update-script = pkgs.writeShellScriptBin "pre-update-script.sh" ''
    set -euxo pipefail

    echo "Resonite Update" > "${reason-file-path}"
  '';
  post-update-clean = pkgs.writeShellScriptBin "post-update-clean.sh" ''
    set -euxo pipefail

    sleep 5
    rm -f "${reason-file-path}"
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

    headless-update-service = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = ''
        The name of the resonite-headless-update service ending in ".service".
      '';
      default = "resonite-headless-update.service";
    };

    update-reason-file-path = lib.mkOption {
      type = lib.types.nonEmptyStr;
      description = ''
        The name of the resonite-headless-update service ending in ".service".
      '';
      default = "/run/${service-name}/update_reason.txt";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services = {
      "${service-name}" = {
        description = service-name;
        serviceConfig = {
          Type = "exec";
          DynamicUser = true;
          ExecStart = lib.getExe launch-script;
          TimeoutStopSec =
            "${(builtins.toString (cfg.shutdown-seconds + 60))}s";
          Restart = "always";
          KillSignal = "SIGINT";
          RuntimeDirectory = service-name;
          RuntimeDirectoryMode = 722;
        };
        bindsTo = [ cfg.headless-service ];
        after = [ cfg.headless-service ];
        wantedBy = [ cfg.headless-service ];
      };
      "${service-name}-update-check-watch" = {
        description =
          "Watches ${cfg.headless-update-service}.service to generate a 'Resonite Update' update reason";
        serviceConfig = {
          Type = "oneshot";
          DynamicUser = true;
          ExecStart = lib.getExe pre-update-script;
        };
        before = [ cfg.headless-update-service ];
        wantedBy = [ cfg.headless-update-service ];
      };
      "${service-name}-post-update-clean" = {
        description = ''
          Cleans "${reason-file-path}" after ${cfg.headless-update-service}.service runs'';
        serviceConfig = {
          Type = "oneshot";
          ExecStart = lib.getExe post-update-clean;
          DynamicUser = true;
        };
        after = [ cfg.headless-update-service ];
        wantedBy = [ cfg.headless-update-service ];
      };
    };
  };
}
