{ pkgs, self }:
let
  lib = pkgs.lib;
  kernels = self.legacyPackages.aarch64-linux;
  versions = [
    "6_18_34"
    "6_18_39"
    "6_18_42"
  ];
  patch = import ../pkgs/linux-rpi/ipv4-tcp-options-rcu.nix;
  # Fetch on the check's build platform. The kernel package's fetcher is ARM,
  # which cannot run on a clean x86 runner even though the source is identical.
  sources = lib.genAttrs versions (
    version:
    let
      original = kernels."linux_rpi5_v${version}".src;
    in
    assert original.outputHashMode == "recursive";
    pkgs.fetchzip {
      inherit (original) name url;
      hash = original.outputHash;
    }
  );
  models = [
    "02"
    "3"
    "4"
    "5"
  ];
  wired = lib.all (
    version:
    lib.all (
      model:
      lib.count (
        p: p.name == patch.name && p.patch == patch.patch
      ) kernels."linux_rpi${model}_v${version}".kernelPatches == 1
    ) models
  ) versions;
in
assert wired;
assert lib.all (source: source.system == pkgs.stdenv.buildPlatform.system) (
  builtins.attrValues sources
);
pkgs.runCommand "ipv4-tcp-options-rcu-source-regression"
  {
    nativeBuildInputs = [
      pkgs.patch
      pkgs.python3
    ];
  }
  ''
    ${lib.concatMapStringsSep "\n" (version: ''
      mkdir -p ${version}/net/ipv4
      cp ${sources.${version}}/net/ipv4/{af_inet.c,tcp_ipv4.c} ${version}/net/ipv4/
      chmod -R u+w ${version}
      python3 ${./ipv4-tcp-options-rcu.py} vulnerable ${version}
      patch --batch --fuzz=0 -p1 -d ${version} < ${patch.patch}
      python3 ${./ipv4-tcp-options-rcu.py} fixed ${version}
      # Reapplying a backport must fail, rather than silently mispatch a new source.
      if patch --batch --forward --fuzz=0 -p1 -d ${version} < ${patch.patch}; then
        echo "duplicate backport unexpectedly accepted" >&2
        exit 1
      fi
    '') versions}
    touch "$out"
  ''
