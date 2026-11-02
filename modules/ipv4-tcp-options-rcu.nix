# Reusable with a retained Pi platform input: no firmware or nixpkgs repin.
{ config, lib, ... }:
let
  version = config.boot.kernelPackages.kernel.modDirVersion;
in
{
  assertions = [
    {
      assertion = lib.versions.majorMinor version == "6.18";
      message = "The Kaiba CVE-2026-98432 backport is qualified for the Linux 6.18 series.";
    }
  ];
  boot.kernelPatches = lib.optional (lib.versionOlder version "6.18.56") (
    import ../pkgs/linux-rpi/ipv4-tcp-options-rcu.nix
  );
}
