{ self, nixpkgs, sops-nix, systems }:

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
  rpi-otp-derived-key-sops-nix = pkgs.callPackage ./rpi-otp-derived-key-sops.nix {
    inherit self sops-nix;
  };
})
