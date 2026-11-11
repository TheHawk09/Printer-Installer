# ===============================================================================
# GTG NETWORK COPIER HOME MANAGER MODULE
# Manages user-level CUPS preferences (~/.cups/lpoptions) without root access
# ===============================================================================

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkIf mkEnableOption types concatStringsSep concatMapStrings optionalString;
  cfg = config.programs.gtg-printers;
  defaults = import ./lib/defaults.nix;

  lpoptionsText = ''
    Default ${cfg.defaultPrinter}
    ${concatMapStrings (p: optionalString cfg.duplex "Dest ${p} sides=two-sided-long-edge\n") cfg.printers}'';
in
{
  options.programs.gtg-printers = {
    enable = mkEnableOption "GTG Network Copier user preferences (Default printer & duplex options)";

    printers = mkOption {
      type = types.listOf types.str;
      default = defaults.printerNames;
      description = "List of GTG copiers to configure in user lpoptions.";
    };

    defaultPrinter = mkOption {
      type = types.str;
      default = defaults.defaultPrinter;
      description = "Default printer designated for user-context applications.";
    };

    duplex = mkOption {
      type = types.bool;
      default = true;
      description = "Enforce two-sided long-edge duplex printing by default in user lpoptions.";
    };

    autostartPaperCut = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to configure an XDG autostart desktop entry for the PaperCut MF Client.";
    };

    paperCutClientPath = mkOption {
      type = types.str;
      default = "$HOME/papercut/client/pc-client-linux.sh";
      description = "Path to the PaperCut client launch script.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.elem cfg.defaultPrinter cfg.printers;
        message = "programs.gtg-printers.defaultPrinter ('${cfg.defaultPrinter}') must be one of the configured printers in programs.gtg-printers.printers: ${concatStringsSep ", " cfg.printers}";
      }
    ];

    # 1. Generate lpoptions declaratively in user space
    # CUPS client libraries (lp, lpr) historically read ~/.cups/lpoptions directly
    # rather than respecting XDG_CONFIG_HOME (~/.config/cups/lpoptions).
    # We provision both to guarantee full compatibility with both legacy CUPS and XDG tools.
    home.file.".cups/lpoptions".text = lpoptionsText;
    xdg.configFile."cups/lpoptions".text = lpoptionsText;

    # 2. Optional XDG autostart entry for PaperCut MF Client on desktop login
    xdg.configFile."autostart/papercut-client.desktop" = mkIf cfg.autostartPaperCut {
      text = ''
        [Desktop Entry]
        Type=Application
        Name=PaperCut MF Client
        Exec=${cfg.paperCutClientPath}
        Hidden=false
        NoDisplay=false
        X-GNOME-Autostart-enabled=true
        Comment=PaperCut MF Client for GTG Network Copiers
      '';
    };
  };
}