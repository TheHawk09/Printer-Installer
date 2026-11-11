# ===============================================================================
# GTG NETWORK COPIER HOME MANAGER MODULE
# Manages user-level CUPS preferences (~/.cups/lpoptions) without root access
# ===============================================================================

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkIf mkEnableOption types concatStringsSep concatMapStrings optionalString;
  cfg = config.programs.gtg-printers;
in
{
  options.programs.gtg-printers = {
    enable = mkEnableOption "GTG Network Copier user preferences (Default printer & duplex options)";

    printers = mkOption {
      type = types.listOf types.str;
      default = [ "L-Kopiator" "TB-Kopiator" "PB-Kopiator" ];
      description = "List of GTG copiers to configure in user lpoptions.";
    };

    defaultPrinter = mkOption {
      type = types.str;
      default = "L-Kopiator";
      description = "Default printer designated for user-context applications.";
    };

    duplex = mkOption {
      type = types.bool;
      default = true;
      description = "Enforce two-sided long-edge duplex printing by default in user lpoptions.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.elem cfg.defaultPrinter cfg.printers;
        message = "programs.gtg-printers.defaultPrinter ('${cfg.defaultPrinter}') must be one of the configured printers in programs.gtg-printers.printers: ${concatStringsSep ", " cfg.printers}";
      }
    ];

    # Generate ~/.cups/lpoptions declaratively in user space
    xdg.configFile."cups/lpoptions".text = ''
      Default ${cfg.defaultPrinter}
      ${concatMapStrings (p: optionalString cfg.duplex "Dest ${p} sides=two-sided-long-edge\n") cfg.printers}'';
  };
}