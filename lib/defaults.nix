# ===============================================================================
# GTG NETWORK COPIER CONSTANTS & DEFAULT PARAMETERS
# Shared single-source-of-truth metadata for NixOS and Home Manager modules
# ===============================================================================

let
  printers = [
    {
      name = "L-Kopiator";
      location = "GTG Campus - L Building";
      description = "GTG Copier (L Building)";
    }
    {
      name = "TB-Kopiator";
      location = "GTG Campus - TB Building";
      description = "GTG Copier (TB Building)";
    }
    {
      name = "PB-Kopiator";
      location = "GTG Campus - PB Building";
      description = "GTG Copier (PB Building)";
    }
  ];
in
{
  serverHost = "gtcps001.gtc.local";
  serverIp = "172.16.0.32";
  internalDns = [ "172.16.0.7" "172.16.0.8" ];
  defaultPrinter = "L-Kopiator";

  inherit printers;
  printerNames = map (p: p.name) printers;
}