# ===============================================================================
# GTG NETWORK COPIER DECLARATIVE MODULE FOR NIXOS
# Offline-safe, declarative configuration for L-Kopiator, TB-Kopiator, PB-Kopiator
# ===============================================================================

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption mkIf mkEnableOption types concatStringsSep;
  cfg = config.services.gtg-printers;

  # Pure Nix derivation providing smbspool as an isolated CUPS backend in /lib/cups/backend/smb
  # Using NixOS's first-class services.printing.drivers mechanism builds the backend purely in /nix/store
  smbBackend = pkgs.runCommand "cups-backend-smb" {
    meta = with lib; {
      description = "CUPS smbspool backend without background Samba daemons";
      license = licenses.gpl3Plus;
    };
  } ''
    mkdir -p $out/lib/cups/backend
    ln -s ${pkgs.samba}/bin/smbspool $out/lib/cups/backend/smb
  '';
in
{
  options.services.gtg-printers = {
    enable = mkEnableOption "GTG Network Copiers (L-Kopiator, TB-Kopiator, PB-Kopiator)";

    serverIp = mkOption {
      type = types.str;
      default = "172.16.0.32";
      description = "Internal direct fallback IP address of the GTG print server.";
    };

    serverHost = mkOption {
      type = types.str;
      default = "gtcps001.gtc.local";
      description = "Fully qualified domain name of the GTG print server.";
    };

    useDirectIp = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to target the server IP directly to prevent internal DNS or DoH resolution failures.";
    };

    printers = mkOption {
      type = types.listOf types.str;
      default = [ "L-Kopiator" "TB-Kopiator" "PB-Kopiator" ];
      description = "List of GTG copier queues to provision declaratively.";
    };

    defaultPrinter = mkOption {
      type = types.str;
      default = "L-Kopiator";
      description = "Default printer queue to designate in CUPS for user applications.";
    };

    duplex = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to enforce two-sided (duplex) long-edge printing policy by default.";
    };

    installClientTools = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to include samba client utilities (smbclient) in environment.systemPackages.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.elem cfg.defaultPrinter cfg.printers;
        message = "services.gtg-printers.defaultPrinter ('${cfg.defaultPrinter}') must be one of the configured printers in services.gtg-printers.printers: ${concatStringsSep ", " cfg.printers}";
      }
    ];

    # 1. Ensure CUPS printing subsystem is active and load pure store backend
    services.printing = {
      enable = true;
      drivers = [ smbBackend ];
    };

    # 2. Compatibility fallback: ensure legacy paths find smbspool
    systemd.tmpfiles.rules = [
      "L+ /var/lib/cups/backend/smb - - - - ${pkgs.samba}/bin/smbspool"
    ];

    # 3. Optional client tools (avoids bloating system profile with full Samba suite by default)
    environment.systemPackages = mkIf cfg.installClientTools [
      pkgs.samba
    ];

    # 4. Declaratively provision selected copier queues
    # Best Practice: Use "raw" model so lpadmin does not perform blocking IPP queries
    # across the network during 'nixos-rebuild switch' when offline or off-campus.
    hardware.printers = {
      ensurePrinters = map (name: {
        inherit name;
        location = "GTG Campus - ${name}";
        deviceUri = "smb://${if cfg.useDirectIp then cfg.serverIp else cfg.serverHost}/${name}";
        model = "raw";
        ppdOptions = mkIf cfg.duplex {
          sides = "two-sided-long-edge";
        };
      }) cfg.printers;
      ensureDefaultPrinter = cfg.defaultPrinter;
    };
  };
}