inputs@{
  config,
  lib,
  pkgs,
  ...
}:

let
  service-name = "resonite-dominion";
  cfg = config.services.${service-name};

  package = pkgs.rustPlatform.buildRustPackage rec {
    pname = service-name;
    version = "1.0.0";

    src = ./.;
    cargoLock.lockFile = ./Cargo.lock;
  };
  
  launch-script = pkgs.writeShellScriptBin "launch-script" ''
    set -euxo pipefail
    exec ${package}/bin/resonite-dominion --port ${cfg.port} --shutdown-seconds ${cfg.shutdown-seconds}
  '';
in
{
  ##### interface. here we define the options that users of our service can specify
  options.services.${service-name} = {
    enable = lib.mkEnableOption "";
    shutdown-seconds = lib.mkOption {
      type = lib.types.ints.u32;
      description = ''
        The name of the steam account to use.
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
      type = lib.types.nonEmptyString;
      description = ''
        The name of the resonite-headless service ending in ".service".
      '';
      default = "resonite-headless.service";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services = {
      "${service-name}" = {
        description = service-name;
        serviceConfig = {
          Type = "exec";
          ExecStart = "${launch-script}/bin/${launch-script}";
          TimeoutStartSec = "30m";
          Restart = "always";
          KillSignal = "SIGINT"; # Resonite doesn't respond to SIGTERM and dies immediately
        };
        restartTriggers = [
          cfg.shutdown-seconds
          cfg.headless-service
        ];
        requires = [ cfg.headless-service ];
        before = [ cfg.headless-service ];
      };
    };
  };
}
