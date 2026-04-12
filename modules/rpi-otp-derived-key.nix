{ config, lib, pkgs, ... }:
let
  cfg = config.services.rpiOtpDerivedKey;
  requiredOptionsSet = cfg.format != null;
  isAbsolutePath = path: lib.hasPrefix "/" path;

  defaultPackage = let
    localLibraspberrypi = pkgs.callPackage ../pkgs/raspberrypi/libraspberrypi.nix {};
    localRpiOtpPrivateKey = pkgs.callPackage ../pkgs/raspberrypi/rpi-otp-private-key.nix {
      libraspberrypi = localLibraspberrypi;
    };
  in pkgs.callPackage ../pkgs/raspberrypi/rpi-otp-derived-key.nix {
    rpiOtpPrivateKey = localRpiOtpPrivateKey;
  };

  saltDir = builtins.dirOf cfg.saltFile;
  outputDir = builtins.dirOf cfg.outputPath;
in
{
  options.services.rpiOtpDerivedKey = {
    enable = lib.mkEnableOption "Raspberry Pi OTP-derived key generation service";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs."rpi-otp-derived-key" or defaultPackage;
      description = ''
        Package providing the `rpi-otp-derived-key` executable.
      '';
    };

    format = lib.mkOption {
      type = with lib.types; nullOr (enum [ "hex" "binary" "ed25519" "age" ]);
      default = null;
      example = "age";
      description = ''
        Output format to generate.
      '';
    };

    saltFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/rpi-otp-derived-key/salt";
      example = "/var/lib/rpi-otp-derived-key/salt";
      description = ''
        Path to the salt file. By default this is a persistent path under
        `/var/lib` so the same salt survives reboots and normal OS updates.
        This file is injected into the service via `systemd`'s
        `LoadCredential=` mechanism and is not passed as a literal command-line
        value.
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

    info = lib.mkOption {
      type = with lib.types; nullOr str;
      default = null;
      example = "ssh-host-key";
      description = ''
        Optional public HKDF domain-separation string.
      '';
    };

    outputPath = lib.mkOption {
      type = lib.types.str;
      default = "/run/rpi-otp-derived-key/key";
      description = ''
        Path where the derived key material will be written.
      '';
    };

    owner = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = ''
        User ownership to apply to the generated key file.
      '';
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "root";
      description = ''
        Group ownership to apply to the generated key file.
      '';
    };

    mode = lib.mkOption {
      type = lib.types.str;
      default = "0400";
      example = "0440";
      description = ''
        File mode to apply to the generated key file.
      '';
    };

    wantedBy = lib.mkOption {
      type = with lib.types; listOf str;
      default = [ "multi-user.target" ];
      description = ''
        Targets that should pull in the key generation service.
      '';
    };

    before = lib.mkOption {
      type = with lib.types; listOf str;
      default = [];
      example = [ "sshd.service" ];
      description = ''
        Units that should start after the key generation service.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.format != null;
        message = "services.rpiOtpDerivedKey.format must be set when the module is enabled.";
      }
      {
        assertion = isAbsolutePath cfg.outputPath;
        message = "services.rpiOtpDerivedKey.outputPath must be an absolute path.";
      }
      {
        assertion = isAbsolutePath cfg.saltFile;
        message = "services.rpiOtpDerivedKey.saltFile must be an absolute path.";
      }
      {
        assertion = !cfg.generateSalt || !(cfg.saltFile == "/run" || lib.hasPrefix "/run/" cfg.saltFile);
        message = "services.rpiOtpDerivedKey.saltFile must not point inside /run when services.rpiOtpDerivedKey.generateSalt is enabled.";
      }
      {
        assertion = builtins.match "0[0-7]{3}" cfg.mode != null;
        message = "services.rpiOtpDerivedKey.mode must be a four-digit octal string such as \"0400\".";
      }
    ];

    systemd.services."rpi-otp-derived-key-salt" = lib.mkIf cfg.generateSalt {
      description = "Generate persistent salt for rpi-otp-derived-key";
      before = [ "rpi-otp-derived-key.service" ];
      unitConfig = {
        ConditionPathExists = "!${cfg.saltFile}";
        RequiresMountsFor = [ saltDir ];
      };
      serviceConfig = {
        Type = "oneshot";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ saltDir ];
      };
      script = ''
        set -euo pipefail

        salt_dir=${lib.escapeShellArg saltDir}
        salt_path=${lib.escapeShellArg cfg.saltFile}
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

    systemd.services."rpi-otp-derived-key" = lib.mkIf requiredOptionsSet {
      description = "Generate device-unique key material from Raspberry Pi OTP";
      wantedBy = cfg.wantedBy;
      before = cfg.before;
      wants = lib.optional cfg.generateSalt "rpi-otp-derived-key-salt.service";
      after = lib.optional cfg.generateSalt "rpi-otp-derived-key-salt.service";
      unitConfig.RequiresMountsFor = lib.unique [
        saltDir
        outputDir
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ outputDir ];
        LoadCredential = [ "salt:${cfg.saltFile}" ];
      };
      script = ''
        set -euo pipefail

        output_dir=${lib.escapeShellArg outputDir}
        output_path=${lib.escapeShellArg cfg.outputPath}
        owner=${lib.escapeShellArg cfg.owner}
        group=${lib.escapeShellArg cfg.group}
        mode=${lib.escapeShellArg cfg.mode}

        ${pkgs.coreutils}/bin/mkdir -p "$output_dir"
        tmp_path="$(${pkgs.coreutils}/bin/mktemp "$output_dir/.rpi-otp-derived-key.tmp.XXXXXX")"
        trap '${pkgs.coreutils}/bin/rm -f "$tmp_path"' EXIT

        cmd=(
          ${lib.getExe cfg.package}
          --format ${lib.escapeShellArg cfg.format}
          --salt-file "$CREDENTIALS_DIRECTORY/salt"
        )

        ${lib.optionalString (cfg.info != null) ''
          cmd+=(--info ${lib.escapeShellArg cfg.info})
        ''}

        "''${cmd[@]}" > "$tmp_path"

        ${pkgs.coreutils}/bin/chown "$owner:$group" "$tmp_path"
        ${pkgs.coreutils}/bin/chmod "$mode" "$tmp_path"
        ${pkgs.coreutils}/bin/mv -f "$tmp_path" "$output_path"

        trap - EXIT
      '';
    };
  };
}
