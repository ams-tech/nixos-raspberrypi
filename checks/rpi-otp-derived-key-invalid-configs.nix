{ lib, nixpkgs, pkgs, self }:

let
  evalConfig =
    modules:
    nixpkgs.lib.nixosSystem {
      system = pkgs.stdenv.hostPlatform.system;
      modules =
        [
          self.lib.inject-overlays
          self.nixosModules.bootloader
          self.nixosModules.rpi-otp-derived-key
          {
            system.stateVersion = "25.11";
          }
        ]
        ++ modules;
    };

  expectFailure =
    name: modules:
    let
      result = builtins.tryEval (
        builtins.deepSeq
          (evalConfig modules).config.system.build.toplevel
          true
      );
    in
    assert !result.success;
    name;

  cases = [
    (expectFailure "needed-for-boot-non-run-path" [
      {
        boot.initrd.systemd.enable = true;
        boot.loader.supportsInitrdSecrets = true;
        boot.loader.raspberry-pi.enable = true;

        services.rpiOtpDerivedKey = {
          enable = true;
          secrets.bad = {
            format = "hex";
            path = "/var/lib/bad-key";
            neededForBoot = true;
          };
        };
      }
    ])
    (expectFailure "needed-for-boot-non-root-owner" [
      {
        boot.initrd.systemd.enable = true;
        boot.loader.supportsInitrdSecrets = true;
        boot.loader.raspberry-pi.enable = true;

        services.rpiOtpDerivedKey = {
          enable = true;
          secrets.bad = {
            format = "hex";
            path = "/run/bad-key";
            owner = "alice";
            neededForBoot = true;
          };
        };
      }
    ])
    (expectFailure "needed-for-boot-without-raspberry-pi-bootloader" [
      {
        boot.initrd.systemd.enable = true;
        boot.loader.supportsInitrdSecrets = true;

        services.rpiOtpDerivedKey = {
          enable = true;
          secrets.bad = {
            format = "hex";
            path = "/run/bad-key";
            neededForBoot = true;
          };
        };
      }
    ])
  ];
in
pkgs.writeText "rpi-otp-derived-key-invalid-configs" ''
  ${lib.concatStringsSep "\n" cases}
''
