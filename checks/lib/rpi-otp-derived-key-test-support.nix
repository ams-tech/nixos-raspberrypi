{ lib
, pkgs
, mockOtpHex ? "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
, }:

let
  otpDerivedKeyLib = import ../../lib/rpi-otp-derived-key.nix { };

  mockRpiOtpPrivateKey = pkgs.writeShellApplication {
    name = "rpi-otp-private-key";
    text = ''
      set -euo pipefail

      while [[ $# -gt 0 ]]; do
        case "$1" in
          -l|-o)
            shift 2
            ;;
          -h|--help)
            cat <<'EOF'
      Usage: rpi-otp-private-key [-l WORDS] [-o OFFSET]
      EOF
            exit 0
            ;;
          --)
            shift
            break
            ;;
          *)
            shift
            ;;
        esac
      done

      printf '%s\n' '${mockOtpHex}'
    '';
  };

  testOverlay = final: prev: {
    rpi-otp-private-key = mockRpiOtpPrivateKey;
    rpi-otp-derived-key =
      (prev.callPackage ../../pkgs/raspberrypi/rpi-otp-derived-key.nix {
        rpiOtpPrivateKey = final.rpi-otp-private-key;
      }).overrideAttrs (old: {
        meta = (old.meta or { }) // {
          platforms = lib.platforms.linux;
        };
      });
  };
in
{
  persistentSaltPathForName = name: "/var/lib/rpi-otp-derived-key/salt/${otpDerivedKeyLib.saltPathComponentForName name}";
  testPkgs = pkgs.extend testOverlay;
}
