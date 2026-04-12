{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.services.rpiOtpDerivedKey;
  users = config.users.users;
  formats = [
    "hex"
    "binary"
    "ed25519"
    "age"
  ];
  storeDir = builtins.storeDir;
  isAbsolutePath = path: lib.hasPrefix "/" path;
  isRunPath = path: path == "/run" || lib.hasPrefix "/run/" path;
  isStorePath = path: path == storeDir || lib.hasPrefix "${storeDir}/" path;
  shouldManageTmpfilesDir = dir: !(builtins.elem dir [ "/" "/run" "/tmp" "/var" "/var/lib" ]);

  defaultLibraspberrypi = pkgs.callPackage ../pkgs/raspberrypi/libraspberrypi.nix { };
  defaultRpiOtpPrivateKey = pkgs.callPackage ../pkgs/raspberrypi/rpi-otp-private-key.nix {
    libraspberrypi = defaultLibraspberrypi;
  };
  defaultPackage = pkgs.callPackage ../pkgs/raspberrypi/rpi-otp-derived-key.nix {
    rpiOtpPrivateKey = defaultRpiOtpPrivateKey;
  };
  defaultOtpHelperPackage = lib.optional (
    builtins.elem pkgs.stdenv.hostPlatform.system [
      "armv6l-linux"
      "armv7l-linux"
      "aarch64-linux"
    ]
  ) (pkgs."rpi-otp-private-key" or defaultRpiOtpPrivateKey);
  defaultInitrdPackages = [
    pkgs.age
    pkgs.coreutils
    pkgs.openssl
    pkgs.xxd
  ] ++ defaultOtpHelperPackage;

  secretType = lib.types.submodule (
    { config, ... }:
    {
      options = {
        name = lib.mkOption {
          type = lib.types.str;
          default = config._module.args.name;
          description = ''
            Name of the derived key output.
          '';
        };

        format = lib.mkOption {
          type = lib.types.enum formats;
          example = "age";
          description = ''
            Output format to generate for this secret.
          '';
        };

        info = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          example = "ssh-host-key";
          description = ''
            Optional public HKDF domain-separation string.
          '';
        };

        path = lib.mkOption {
          type = lib.types.str;
          default = "/run/rpi-otp-derived-key/${config.name}";
          description = ''
            Path where the derived secret is written.
            Secrets with `neededForBoot = true` should keep this under `/run`.
          '';
        };

        neededForBoot = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = ''
            Generate this secret in `boot.initrd.systemd` instead of stage 2.
            This is useful for consumers that need the derived secret during the
            systemd initrd phase.

            With the default persistent `saltFile` under `/var/lib`, initrd
            generation can happen after `sysroot` is mounted. If you need the
            secret before that point, set `saltFile` to a `/run/...` path and
            provide `initrdSaltSource` so the module can project that salt into
            the initrd with `boot.initrd.secrets`.
          '';
        };

        owner = lib.mkOption {
          type = with lib.types; nullOr str;
          default = null;
          example = "my-service";
          description = ''
            Owner of the derived secret. `null` means `root`.
          '';
        };

        group = lib.mkOption {
          type = with lib.types; nullOr str;
          default =
            if config.owner != null && builtins.hasAttr config.owner users then
              users.${config.owner}.group
            else
              null;
          defaultText = lib.literalMD "The owning user's primary group when available, otherwise `root`.";
          description = ''
            Group of the derived secret. `null` means `root`.
          '';
        };

        mode = lib.mkOption {
          type = lib.types.str;
          default = "0400";
          example = "0440";
          description = ''
            File mode to apply to the derived secret.
          '';
        };

        wantedBy = lib.mkOption {
          type = with lib.types; listOf str;
          default = if config.neededForBoot then [ "initrd.target" ] else [ "multi-user.target" ];
          description = ''
            Targets that should pull in this derived-secret service in the
            relevant systemd stage.
          '';
        };

        before = lib.mkOption {
          type = with lib.types; listOf str;
          default = [ ];
          example = [ "sshd.service" ];
          description = ''
            Units that should start after this derived-secret service.
          '';
        };
      };
    }
  );

  effectiveSecrets = cfg.secrets;
  stage2Secrets = lib.filterAttrs (_: secret: !secret.neededForBoot) effectiveSecrets;
  initrdSecrets = lib.filterAttrs (_: secret: secret.neededForBoot) effectiveSecrets;
  hasInitrdSecrets = initrdSecrets != { };
  saltDir = builtins.dirOf cfg.saltFile;
  initrdSaltFile =
    if isRunPath cfg.saltFile || isStorePath cfg.saltFile then
      cfg.saltFile
    else
      "/sysroot${cfg.saltFile}";

  mkSecretInstances =
    secrets:
    lib.mapAttrs (
      name: secretCfg:
      let
        outputDir = builtins.dirOf secretCfg.path;
      in
      secretCfg
      // {
        inherit name outputDir;
        unitSuffix = utils.escapeSystemdPath name;
        unitName = "rpi-otp-derived-key-${utils.escapeSystemdPath name}";
        ownerName = if secretCfg.owner != null then secretCfg.owner else "root";
        groupName = if secretCfg.group != null then secretCfg.group else "root";
      }
    ) secrets;

  stage2SecretInstances = mkSecretInstances stage2Secrets;
  initrdSecretInstances = mkSecretInstances initrdSecrets;
  secretInstances = stage2SecretInstances // initrdSecretInstances;

  managedOutputDirs = lib.unique (
    lib.filter
      (dir: shouldManageTmpfilesDir dir && (!cfg.generateSalt || dir != saltDir))
      (lib.mapAttrsToList (_: secret: secret.outputDir) secretInstances)
  );

  tmpfilesRules =
    lib.optionals (cfg.generateSalt && shouldManageTmpfilesDir saltDir) [
      "d ${saltDir} 0700 root root - -"
    ]
    ++ map (dir: "d ${dir} 0711 root root - -") managedOutputDirs;

  secretAssertions = lib.flatten (
    lib.mapAttrsToList (
      name: secret:
      [
        {
          assertion = isAbsolutePath secret.path;
          message = "services.rpiOtpDerivedKey.secrets.${lib.strings.escapeNixIdentifier name}.path must be an absolute path.";
        }
        {
          assertion = builtins.match "0[0-7]{3}" secret.mode != null;
          message = "services.rpiOtpDerivedKey.secrets.${lib.strings.escapeNixIdentifier name}.mode must be a four-digit octal string such as \"0400\".";
        }
        {
          assertion = secret.path != cfg.saltFile;
          message = "services.rpiOtpDerivedKey.secrets.${lib.strings.escapeNixIdentifier name}.path must not be the same as services.rpiOtpDerivedKey.saltFile.";
        }
        {
          assertion = !secret.neededForBoot || isRunPath secret.path;
          message = "services.rpiOtpDerivedKey.secrets.${lib.strings.escapeNixIdentifier name}.path must point inside /run when neededForBoot is enabled.";
        }
        {
          assertion = !secret.neededForBoot || secret.owner == null || secret.owner == "root";
          message = "services.rpiOtpDerivedKey.secrets.${lib.strings.escapeNixIdentifier name}.owner must be root when neededForBoot is enabled.";
        }
        {
          assertion = !secret.neededForBoot || secret.group == null || secret.group == "root";
          message = "services.rpiOtpDerivedKey.secrets.${lib.strings.escapeNixIdentifier name}.group must be root when neededForBoot is enabled.";
        }
      ]
    ) secretInstances
  );

  mkSaltService =
    {
      initrd ? false,
      targetSaltFile,
      secretSet,
    }:
    lib.optionalAttrs (cfg.generateSalt && secretSet != { }) {
      "rpi-otp-derived-key-salt" = {
        description =
          if initrd then
            "Generate persistent salt for rpi-otp-derived-key in initrd"
          else
            "Generate persistent salt for rpi-otp-derived-key";
        before = lib.mapAttrsToList (_: secret: "${secret.unitName}.service") secretSet;
        requires = lib.optionals (initrd && targetSaltFile != cfg.saltFile) [ "sysroot.mount" ];
        after = lib.optionals (initrd && targetSaltFile != cfg.saltFile) [ "sysroot.mount" ];
        unitConfig = {
          ConditionPathExists = "!${targetSaltFile}";
          RequiresMountsFor = [ (builtins.dirOf targetSaltFile) ];
        };
        serviceConfig = {
          Type = "oneshot";
          UMask = "0077";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ (builtins.dirOf targetSaltFile) ];
        };
        script = ''
          set -euo pipefail

          salt_dir=${lib.escapeShellArg (builtins.dirOf targetSaltFile)}
          salt_path=${lib.escapeShellArg targetSaltFile}
          salt_length=${toString cfg.saltLength}

          ${pkgs.coreutils}/bin/mkdir -p "$salt_dir"

          if [[ -e "$salt_path" ]]; then
            exit 0
          fi

          tmp_path="$(${pkgs.coreutils}/bin/mktemp "$salt_dir/.rpi-otp-derived-key-salt.tmp.XXXXXX")"
          trap '${pkgs.coreutils}/bin/rm -f "$tmp_path"' EXIT

          ${pkgs.openssl}/bin/openssl rand -out "$tmp_path" "$salt_length"

          ${pkgs.coreutils}/bin/chown root:root "$tmp_path"
          ${pkgs.coreutils}/bin/chmod 0400 "$tmp_path"
          ${pkgs.coreutils}/bin/mv -f "$tmp_path" "$salt_path"

          trap - EXIT
        '';
      };
    };

  mkSecretServices =
    {
      initrd ? false,
      targetSaltFile,
      secretSet,
    }:
    lib.mapAttrs' (
      _: secret:
      lib.nameValuePair secret.unitName {
        description = "Generate device-unique key material from Raspberry Pi OTP for ${secret.name}";
        wantedBy = secret.wantedBy;
        before = secret.before;
        wants = lib.optional cfg.generateSalt "rpi-otp-derived-key-salt.service";
        requires = lib.optionals (initrd && targetSaltFile != cfg.saltFile) [ "sysroot.mount" ];
        after =
          lib.optionals initrd [ "initrd-nixos-copy-secrets.service" ]
          ++ lib.optionals (initrd && targetSaltFile != cfg.saltFile) [ "sysroot.mount" ]
          ++ lib.optional cfg.generateSalt "rpi-otp-derived-key-salt.service";
        unitConfig.RequiresMountsFor = lib.unique (
          [ secret.outputDir ]
          ++ lib.optionals (!(isRunPath targetSaltFile || isStorePath targetSaltFile)) [ (builtins.dirOf targetSaltFile) ]
        );
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          UMask = "0077";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ReadWritePaths = [ secret.outputDir ];
          LoadCredential = [ "salt:${targetSaltFile}" ];
        };
        script = ''
          set -euo pipefail

          output_dir=${lib.escapeShellArg secret.outputDir}
          output_path=${lib.escapeShellArg secret.path}
          owner=${lib.escapeShellArg secret.ownerName}
          group=${lib.escapeShellArg secret.groupName}
          mode=${lib.escapeShellArg secret.mode}

          ${pkgs.coreutils}/bin/mkdir -p "$output_dir"
          tmp_path="$(${pkgs.coreutils}/bin/mktemp "$output_dir/.${secret.unitSuffix}.tmp.XXXXXX")"
          trap '${pkgs.coreutils}/bin/rm -f "$tmp_path"' EXIT

          cmd=(
            ${lib.getExe cfg.package}
            --format ${lib.escapeShellArg secret.format}
            --salt-file "$CREDENTIALS_DIRECTORY/salt"
          )

          ${lib.optionalString (secret.info != null) ''
            cmd+=(--info ${lib.escapeShellArg secret.info})
          ''}

          "''${cmd[@]}" > "$tmp_path"

          ${pkgs.coreutils}/bin/chown "$owner:$group" "$tmp_path"
          ${pkgs.coreutils}/bin/chmod "$mode" "$tmp_path"
          ${pkgs.coreutils}/bin/mv -f "$tmp_path" "$output_path"

          trap - EXIT
        '';
      }
    ) secretSet;

  stage2SaltService = mkSaltService {
    targetSaltFile = cfg.saltFile;
    secretSet = stage2SecretInstances;
  };

  initrdSaltService = mkSaltService {
    initrd = true;
    targetSaltFile = initrdSaltFile;
    secretSet = initrdSecretInstances;
  };

  stage2SecretServices = mkSecretServices {
    targetSaltFile = cfg.saltFile;
    secretSet = stage2SecretInstances;
  };

  initrdSecretServices = mkSecretServices {
    initrd = true;
    targetSaltFile = initrdSaltFile;
    secretSet = initrdSecretInstances;
  };
in
{
  options.services.rpiOtpDerivedKey = {
    enable = lib.mkEnableOption "Raspberry Pi OTP-derived key generation services";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs."rpi-otp-derived-key" or defaultPackage;
      description = ''
        Package providing the `rpi-otp-derived-key` executable.
      '';
    };

    initrdStorePaths = lib.mkOption {
      type = with lib.types; listOf package;
      default = [ ];
      description = ''
        Extra packages to add to `/bin` in the initrd for secrets with
        `neededForBoot = true`, in addition to the bundled helper set that
        `rpi-otp-derived-key` expects.

        If you override `package`, add any extra initrd-visible helper
        packages that the replacement command needs here.
      '';
    };

    saltFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/rpi-otp-derived-key/salt";
      example = "/var/lib/rpi-otp-derived-key/salt";
      description = ''
        Path to the shared salt file. By default this is a persistent path under
        `/var/lib` so the same salt survives reboots and normal OS updates.
        This file is injected into the services via `systemd`'s
        `LoadCredential=` mechanism and is not passed as a literal command-line
        value.

        When any secret uses `neededForBoot`, keeping the default `/var/lib`
        path means initrd generation can happen after `sysroot` is mounted.
        For secrets that must exist earlier in initrd, point this at a
        `/run/...` path and set `initrdSaltSource` so the module can expose the
        same salt through `boot.initrd.secrets`.
      '';
    };

    initrdSaltSource = lib.mkOption {
      type = with lib.types; nullOr path;
      default = null;
      example = "/persist/secrets/rpi-otp-derived-key-salt";
      description = ''
        Source file to project into the initrd via `boot.initrd.secrets` at
        `saltFile`.

        This is the recommended way to supply a shared salt before `sysroot` is
        mounted when any secret uses `neededForBoot = true`.

        Keep `saltFile` under `/run` when using this option. Also note that if
        the selected bootloader does not support native initrd secrets, NixOS
        will copy this source file into the initrd payload during build time.
      '';
    };

    generateSalt = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Generate a random salt file on first boot when `saltFile` does not
        already exist.
      '';
    };

    saltLength = lib.mkOption {
      type = lib.types.ints.positive;
      default = 32;
      description = ''
        Number of random bytes to generate for a new salt file.
      '';
    };

    secrets = lib.mkOption {
      type = with lib.types; attrsOf secretType;
      default = { };
      description = ''
        Derived secrets keyed by name, similar to `sops.secrets`.
      '';
    };

  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = tmpfilesRules;

    assertions =
      [
        {
          assertion = effectiveSecrets != { };
          message = "services.rpiOtpDerivedKey.enable requires at least one secret in services.rpiOtpDerivedKey.secrets.";
        }
        {
          assertion = isAbsolutePath cfg.saltFile;
          message = "services.rpiOtpDerivedKey.saltFile must be an absolute path.";
        }
        {
          assertion = !cfg.generateSalt || !isStorePath cfg.saltFile;
          message = "services.rpiOtpDerivedKey.saltFile must not point inside the Nix store when services.rpiOtpDerivedKey.generateSalt is enabled.";
        }
        {
          assertion = !cfg.generateSalt || !(cfg.saltFile == "/run" || lib.hasPrefix "/run/" cfg.saltFile);
          message = "services.rpiOtpDerivedKey.saltFile must not point inside /run when services.rpiOtpDerivedKey.generateSalt is enabled.";
        }
        {
          assertion = cfg.initrdSaltSource == null || isRunPath cfg.saltFile;
          message = "services.rpiOtpDerivedKey.saltFile must point inside /run when services.rpiOtpDerivedKey.initrdSaltSource is set.";
        }
        {
          assertion = cfg.initrdSaltSource == null || !cfg.generateSalt;
          message = "services.rpiOtpDerivedKey.generateSalt must be false when services.rpiOtpDerivedKey.initrdSaltSource is set.";
        }
        {
          assertion = !hasInitrdSecrets || config.boot.initrd.systemd.enable;
          message = "services.rpiOtpDerivedKey.secrets.<name>.neededForBoot requires boot.initrd.systemd.enable = true.";
        }
      ]
      ++ secretAssertions;

    warnings = lib.optional (cfg.initrdSaltSource != null && !config.boot.loader.supportsInitrdSecrets) ''
      services.rpiOtpDerivedKey.initrdSaltSource uses boot.initrd.secrets, but the
      current bootloader does not support native initrd secrets. NixOS will copy
      the salt source into the initrd payload during build time, so treat that
      salt as public or use a different early-boot provisioning mechanism.
    '';

    systemd.services = stage2SaltService // stage2SecretServices;

    boot.initrd.secrets = lib.mkIf (cfg.initrdSaltSource != null) {
      "${cfg.saltFile}" = cfg.initrdSaltSource;
    };

    boot.initrd.systemd = lib.mkIf hasInitrdSecrets {
      initrdBin = defaultInitrdPackages ++ cfg.initrdStorePaths;
      storePaths =
        map (source: { inherit source; }) (
          lib.unique (
            [
              cfg.package
            ]
            ++ defaultInitrdPackages
            ++ cfg.initrdStorePaths
          )
        )
        ++ lib.optionals (isStorePath cfg.saltFile) [ cfg.saltFile ];
      services = initrdSaltService // initrdSecretServices;
    };
  };
}
