{ lib, pkgs, self, sops-nix }:

let
  mockSaltFile = pkgs.writeText "rpi-otp-derived-key-salt" (builtins.readFile ./fixtures/rpi-otp-derived-key-salt);
  fixedSaltScript = saltPath: ''
    set -euo pipefail

    salt_dir=${builtins.dirOf saltPath}
    salt_path=${saltPath}

    ${pkgs.coreutils}/bin/mkdir -p "$salt_dir"

    if [[ -e "$salt_path" ]]; then
      exit 0
    fi

    tmp_path="$(${pkgs.coreutils}/bin/mktemp "$salt_dir/.rpi-otp-derived-key-salt.tmp.XXXXXX")"
    trap '${pkgs.coreutils}/bin/rm -f "$tmp_path"' EXIT

    ${pkgs.coreutils}/bin/cp ${mockSaltFile} "$tmp_path"

    ${pkgs.coreutils}/bin/chown root:root "$tmp_path"
    ${pkgs.coreutils}/bin/chmod 0400 "$tmp_path"
    ${pkgs.coreutils}/bin/mv -f "$tmp_path" "$salt_path"

    trap - EXIT
  '';

  testSupport = import ./lib/rpi-otp-derived-key-test-support.nix {
    inherit lib pkgs;
  };
  inherit (testSupport) persistentSaltPathForName testPkgs;
  unsafeSecretName = "user/owned";
  unsafeSaltPath = persistentSaltPathForName unsafeSecretName;

  # Encrypt the fixture with the same derived age identity that the module
  # will regenerate inside the VM.
  generatedSopsFile = pkgs.runCommand "rpi-otp-derived-key-sops-secrets.yaml"
    {
      nativeBuildInputs = [
        testPkgs.rpi-otp-derived-key
        pkgs.sops
      ];
    } ''
        set -euo pipefail

        identity_file="$PWD/identity.txt"
        plaintext_file="$PWD/secrets.yaml"

        rpi-otp-derived-key \
          --format age \
          --salt-file ${mockSaltFile} \
          > "$identity_file"

        public_key="$(sed -n 's/^# public key: //p' "$identity_file")"
        test -n "$public_key"

        cat > "$plaintext_file" <<'EOF'
    test_key: test_value
    nested:
      test:
        file: another value
    EOF

        SOPS_AGE_KEY_FILE="$identity_file" \
          sops --encrypt \
          --age "$public_key" \
          --input-type yaml \
          --output-type yaml \
          "$plaintext_file" > "$out"
  '';
in
testPkgs.testers.runNixOSTest {
  name = "rpi-otp-derived-key-sops-nix";

  nodes.machine =
    { config, lib, ... }:
    {
      imports = [
        sops-nix.nixosModules.sops
        self.nixosModules.rpi-otp-derived-key
      ];

      system.stateVersion = "25.11";

      sops = {
        useSystemdActivation = true;
        validateSopsFiles = false;
        defaultSopsFile = generatedSopsFile;
        defaultSopsFormat = "yaml";
        age.keyFile = config.services.rpiOtpDerivedKey.secrets.age.path;
        secrets.test_key = { };
        secrets."nested/test/file" = { };
      };

      users.groups.alice = { };
      users.users.alice = {
        isSystemUser = true;
        group = "alice";
      };

      users.groups.bob = { };
      users.users.bob = {
        isSystemUser = true;
        group = "bob";
      };

      services.rpiOtpDerivedKey = {
        enable = true;
        secrets.age = {
          format = "age";
          path = "/run/age-keys.txt";
        };
        secrets."${unsafeSecretName}" = {
          format = "hex";
          owner = "alice";
          path = "/var/lib/rpi-otp-derived-key/user-owned";
        };
      };

      systemd.services.sops-install-secrets.after = [ "rpi-otp-derived-key-age.service" ];

      systemd.services.rpi-otp-derived-key-salt-age.script = lib.mkForce ''
        ${fixedSaltScript "/var/lib/rpi-otp-derived-key/salt/age"}
      '';
    };

  testScript = ''
    start_all()

    machine.wait_for_unit("rpi-otp-derived-key-age.service")
    machine.wait_until_succeeds("test -e /var/lib/rpi-otp-derived-key/user-owned")
    machine.wait_for_unit("sops-install-secrets.service")
    machine.wait_for_unit("sysinit.target")

    machine.succeed("systemctl show -P After sops-install-secrets.service | tr ' ' '\\n' | grep -qx 'rpi-otp-derived-key-age.service'")
    machine.succeed("grep -q '^# public key: age1' /run/age-keys.txt")
    machine.succeed("grep -q '^AGE-SECRET-KEY-' /run/age-keys.txt")
    machine.succeed("cat /run/secrets/test_key | grep -q 'test_value'")
    machine.succeed("cat /run/secrets/nested/test/file | grep -q 'another value'")

    machine.succeed("stat -c '%a %U %G' /var/lib/rpi-otp-derived-key | grep -qx '711 root root'")
    machine.succeed("stat -c '%a %U %G' /var/lib/rpi-otp-derived-key/salt/age | grep -qx '400 root root'")
    machine.succeed("stat -c '%a %U %G' ${unsafeSaltPath} | grep -qx '400 root root'")
    machine.succeed("stat -c '%U %G %a' /var/lib/rpi-otp-derived-key/user-owned | grep -q '^alice alice 400$'")
    machine.succeed("su -s /bin/sh alice -c 'cat /var/lib/rpi-otp-derived-key/user-owned >/dev/null'")
    machine.fail("su -s /bin/sh bob -c 'cat /var/lib/rpi-otp-derived-key/user-owned >/dev/null'")
    machine.fail("su -s /bin/sh alice -c 'cat /var/lib/rpi-otp-derived-key/salt/age >/dev/null'")
    machine.fail("su -s /bin/sh alice -c 'cat ${unsafeSaltPath} >/dev/null'")
    machine.fail("su -s /bin/sh bob -c 'cat /var/lib/rpi-otp-derived-key/salt/age >/dev/null'")
    machine.fail("su -s /bin/sh bob -c 'cat ${unsafeSaltPath} >/dev/null'")
  '';
}
