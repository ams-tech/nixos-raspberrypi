{ self, nixpkgs, sops-nix, systems }:

nixpkgs.lib.genAttrs systems (system: let
  pkgs = nixpkgs.legacyPackages.${system};
in {
  rpi-otp-derived-key-sops-nix = pkgs.callPackage ./rpi-otp-derived-key-sops.nix {
    inherit self sops-nix;
  };
})
