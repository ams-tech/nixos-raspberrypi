{ pkgs
, ubootPackage
, ubootBinName ? "u-boot-rpi.bin"
, extlinuxConfBuilder
, firmwareBuilder
, preInstallHook ? null
}:

pkgs.replaceVarsWith {
  src = ./uboot-builder.sh;
  isExecutable = true;

  replacements = {
    inherit (pkgs) bash;
    path = pkgs.lib.makeBinPath [
      pkgs.coreutils
      pkgs.jq
    ];

    uboot = ubootPackage;
    inherit ubootBinName;
    inherit extlinuxConfBuilder;
    inherit firmwareBuilder;
    preInstallHook = pkgs.lib.escapeShellArg (if preInstallHook != null then toString preInstallHook else "");
  };
}
