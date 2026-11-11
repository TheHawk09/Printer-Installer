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
      # 1. Reusable Domain Constants & Metadata
      lib = import ./lib/defaults.nix;

      # 2. Standalone On-Demand Applications: 'nix run'
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
                --prefix PATH : ${pkgs.lib.makeBinPath (with pkgs; [ cups samba coreutils gawk gnugrep gnused iproute2 procps iputils ])}
              ln -s $out/bin/gtg-printers $out/bin/install-printers

              # Ergonomic direct printing shortcut (gtg-print <file.pdf>)
              cat <<EOF > $out/bin/gtg-print
              #!${pkgs.runtimeShell}
              exec "\$(dirname "\$0")/gtg-printers" --print "\$@"
              EOF
              chmod +x $out/bin/gtg-print
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
          gtg-print = pkg;
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
        print = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/gtg-print";
        };
        install-printers = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/install-printers";
        };
      });

      # 3. Standard RFC 0101 Code Formatter: 'nix fmt'
      formatter = forAllSystems (system: (pkgsFor system).nixfmt-rfc-style);

      # 4. Ephemeral Development Shell: 'nix develop'
      devShells = forAllSystems (system:
        let pkgs = pkgsFor system; in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              cups
              samba
              coreutils
              gawk
              gnugrep
              gnused
              iputils
              procps
              shellcheck
              nixfmt-rfc-style
            ];
          };
        }
      );

      # 5. Flake Checks: 'nix flake check'
      checks = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in {
          package = self.packages.${system}.default;
          shellcheck = pkgs.runCommandLocal "check-shellcheck" {
            nativeBuildInputs = [ pkgs.shellcheck ];
          } ''
            shellcheck -e SC2034,SC2154,SC2181,SC1090,SC1091,SC2155 ${./install-printers.sh}
            touch $out
          '';
        }
      );

      # 6. Nixpkgs Overlay
      overlays.default = final: prev: {
        gtg-printers = self.packages.${final.system}.default;
      };

      # 7. Declarative System Module: NixOS
      nixosModules.default = import ./gtg-printers.nix;
      nixosModules.gtg-printers = import ./gtg-printers.nix;

      # 8. Declarative Home Manager Module
      homeManagerModules.default = import ./gtg-home.nix;
      homeManagerModules.gtg-printers = import ./gtg-home.nix;
    };
}