{ pkgs
, firmwareBuilder
, preInstallHook ? null
}:

pkgs.replaceVarsWith {
  src = ./kernelboot-builder.sh;
  isExecutable = true;

  replacements = {
    inherit (pkgs) bash;
    path = pkgs.lib.makeBinPath [
      pkgs.coreutils
      pkgs.gnused
      pkgs.jq
    ];

    inherit firmwareBuilder;
    copyKernels = true;
    preInstallHook = pkgs.lib.escapeShellArg (if preInstallHook != null then toString preInstallHook else "");
  };
}
