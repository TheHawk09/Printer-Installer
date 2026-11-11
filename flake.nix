{
  description = "Enterprise Network Printer Deployment Suite for Linux and NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      # 1. Standalone On-Demand Application: 'nix run'
      # Pure derivation using standard Nixpkgs stdenv & wrapProgram for hermetic execution
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          pkg = pkgs.stdenv.mkDerivation {
            pname = "gtg-printers";
            version = "2.0.0";
            dontUnpack = true;
            nativeBuildInputs = [ pkgs.makeWrapper ];
            installPhase = ''
              mkdir -p $out/bin
              install -Dm755 ${./install-printers.sh} $out/bin/gtg-printers
              wrapProgram $out/bin/gtg-printers \
                --set RUNNING_UNDER_NIX 1 \
                --prefix PATH : ${pkgs.lib.makeBinPath (with pkgs; [ cups samba coreutils gawk gnugrep iproute2 procps iputils ])}
              ln -s $out/bin/gtg-printers $out/bin/install-printers
            '';
            meta = with pkgs.lib; {
              description = "Enterprise network printer deployment and on-demand printing suite for GTG copiers";
              homepage = "https://github.com/TheHawk09/Printer-Installer";
              license = licenses.mit;
              platforms = supportedSystems;
              mainProgram = "gtg-printers";
            };
          };
        in {
          default = pkg;
          gtg-printers = pkg;
          install-printers = pkg;
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/gtg-printers";
        };
        gtg-printers = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/gtg-printers";
        };
        install-printers = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/install-printers";
        };
      });

      # 2. Ephemeral Development Shell: 'nix develop'
      devShells = forAllSystems (system:
        let pkgs = pkgsFor system; in {
          default = pkgs.mkShell {
            packages = with pkgs; [ cups samba coreutils gawk gnugrep iputils procps ];
          };
        }
      );

      # 3. Flake Checks: 'nix flake check'
      checks = forAllSystems (system: {
        default = self.packages.${system}.default;
      });

      # 4. Nixpkgs Overlay
      overlays.default = final: prev: {
        gtg-printers = self.packages.${final.system}.default;
      };

      # 5. Declarative System Module: NixOS
      nixosModules.default = import ./gtg-printers.nix;
      nixosModules.gtg-printers = import ./gtg-printers.nix;

      # 6. Declarative Home Manager Module
      homeManagerModules.default = import ./gtg-home.nix;
      homeManagerModules.gtg-printers = import ./gtg-home.nix;
    };
}