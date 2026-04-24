{ self, nixpkgs, systems }:

let
  sops-nix = {
    nixosModules.sops =
      (builtins.fetchTree {
        type = "github";
        owner = "Mic92";
        repo = "sops-nix";
        rev = "d2e8438d5886e92bc5e7c40c035ab6cae0c41f76";
        narHash = "sha256-0E9PohY/VuESLq0LR4doaH7hTag513sDDW5n5qmHd1Q=";
      }) + "/modules/sops";
  };
in
nixpkgs.lib.genAttrs systems (system:
let
  pkgs = nixpkgs.legacyPackages.${system};
in
{
  rpi-otp-derived-key-before = pkgs.callPackage ./rpi-otp-derived-key-before.nix {
    inherit self;
  };
  rpi-otp-derived-key-invalid-configs = pkgs.callPackage ./rpi-otp-derived-key-invalid-configs.nix {
    inherit self nixpkgs;
  };
  rpi-otp-derived-key-install-time-salt = pkgs.callPackage ./rpi-otp-derived-key-install-time-salt.nix {
    inherit self;
  };
  rpi-otp-derived-key-install-time-otp-check = pkgs.callPackage ./rpi-otp-derived-key-install-time-otp-check.nix {
    inherit self;
  };
  rpi-otp-derived-key-sops-nix = pkgs.callPackage ./rpi-otp-derived-key-sops.nix {
    inherit self sops-nix;
  };
})
