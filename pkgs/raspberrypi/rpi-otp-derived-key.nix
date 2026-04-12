{
  lib,
  writeShellApplication,
  age,
  coreutils,
  openssl,
  python3,
  xxd,
  rpiOtpPrivateKey,
}:

writeShellApplication {
  name = "rpi-otp-derived-key";

  runtimeInputs = [
    age
    coreutils
    openssl
    python3
    xxd
    rpiOtpPrivateKey
  ];

  text = ''
    set -euo pipefail

    die() {
      echo "rpi-otp-derived-key: $*" >&2
      exit 1
    }

    usage() {
      cat <<'EOF'
Usage: rpi-otp-derived-key (--salt STRING | --salt-hex HEX | --salt-file PATH) [options]

Derive deterministic key material from the Raspberry Pi OTP private key
using HKDF-SHA256.

This outputs raw derived key material. If you need a private key for a
specific algorithm, convert or validate the result for that algorithm
separately.

Options:
  --format FORMAT    Output format. Defaults to hex.
  --salt STRING      Salt as a UTF-8 string.
  --salt-hex HEX     Salt as hexadecimal bytes.
  --salt-file PATH   Salt bytes read from a file.
  --info STRING      Optional HKDF info/domain-separation string.
  --info-hex HEX     Optional HKDF info/domain-separation bytes in hex.
  --length BYTES     Number of bytes to derive. Defaults to 32 for hex/binary.
  --binary           Shorthand for --format binary.
  --otp-words WORDS  Number of 32-bit OTP words to read. Defaults to 8.
  --otp-offset WORD  OTP word offset to start reading from. Defaults to 0.
  --list-formats     Show supported output formats.
  -h, --help         Show this help.

Supported FORMAT values:
  hex               Lowercase hexadecimal output.
  binary            Raw binary output.
  ed25519           Unencrypted PKCS#8 PEM-encoded Ed25519 private key.
  age               Native age identity text with a public-key comment.

Notes:
  - The OTP value must be programmed and non-zero.
  - FORMAT affects built-in domain separation for algorithm-specific outputs,
    so `ed25519` and `age` derive different outputs even with the same salt
    and custom info.
  - Salt is usually public. If you want to keep it out of the process list,
    prefer --salt-file.
  - `hex` and `binary` are two representations of the same generic derived
    key material.
  - OpenSSH private-key output is not implemented in this version.
EOF
    }

    list_formats() {
      cat <<'EOF'
hex
binary
ed25519
age
EOF
    }

    is_uint() {
      [[ "$1" =~ ^[0-9]+$ ]]
    }

    is_hex() {
      [[ "$1" =~ ^[0-9A-Fa-f]+$ ]] && (( ''${#1} % 2 == 0 ))
    }

    utf8_to_hex() {
      printf '%s' "$1" | xxd -p -c 999999 | tr -d '\n'
    }

    file_to_hex() {
      xxd -p -c 999999 "$1" | tr -d '\n'
    }

    canonical_hex() {
      printf '%s' "$1" | tr -d '[:space:]:' | tr '[:upper:]' '[:lower:]'
    }

    age_identity_from_hex() {
      python3 - "$1" <<'PY'
import sys

CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"

def polymod(values):
    chk = 1
    for value in values:
        top = chk >> 25
        chk = ((chk & 0x1FFFFFF) << 5) ^ value
        for i, gen in enumerate((0x3B6A57B2, 0x26508E6D, 0x1EA119FA, 0x3D4233DD, 0x2A1462B3)):
            if (top >> i) & 1:
                chk ^= gen
    return chk

def hrp_expand(hrp):
    hrp = hrp.lower()
    return [ord(x) >> 5 for x in hrp] + [0] + [ord(x) & 31 for x in hrp]

def convertbits(data, frombits, tobits, pad=True):
    acc = 0
    bits = 0
    ret = []
    maxv = (1 << tobits) - 1
    max_acc = (1 << (frombits + tobits - 1)) - 1
    for value in data:
        if value < 0 or value >> frombits:
            raise ValueError("invalid data")
        acc = ((acc << frombits) | value) & max_acc
        bits += frombits
        while bits >= tobits:
            bits -= tobits
            ret.append((acc >> bits) & maxv)
    if pad:
        if bits:
            ret.append((acc << (tobits - bits)) & maxv)
    elif bits >= frombits or ((acc << (tobits - bits)) & maxv):
        raise ValueError("invalid padding")
    return ret

def encode(hrp, data):
    lower = hrp.lower() == hrp
    hrp = hrp.lower()
    values = convertbits(data, 8, 5, True)
    checksum_input = hrp_expand(hrp) + values
    mod = polymod(checksum_input + [0, 0, 0, 0, 0, 0]) ^ 1
    checksum = [((mod >> (5 * (5 - i))) & 31) for i in range(6)]
    out = hrp + "1" + "".join(CHARSET[d] for d in values + checksum)
    return out if lower else out.upper()

raw = bytes.fromhex(sys.argv[1])
print(encode("AGE-SECRET-KEY-", raw))
PY
    }

    emit_ed25519_pem() {
      local seed_hex="$1"
      printf '302e020100300506032b657004220420%s' "$seed_hex" \
        | xxd -r -p \
        | openssl pkey -inform DER -outform PEM
    }

    emit_age_identity() {
      local secret_hex="$1"
      local identity recipient

      identity="$(age_identity_from_hex "$secret_hex")"
      recipient="$(printf '%s\n' "$identity" | age-keygen -y)"

      printf '# public key: %s\n' "$recipient"
      printf '%s\n' "$identity"
    }

    salt_hex=""
    user_info_hex=""
    user_length=""
    format="hex"
    otp_words=8
    otp_offset=0

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --format)
          [[ $# -ge 2 ]] || die "--format requires an argument"
          format="''${2,,}"
          shift 2
          ;;
        --salt)
          [[ $# -ge 2 ]] || die "--salt requires an argument"
          [[ -z "$salt_hex" ]] || die "salt specified more than once"
          salt_hex="$(utf8_to_hex "$2")"
          shift 2
          ;;
        --salt-hex)
          [[ $# -ge 2 ]] || die "--salt-hex requires an argument"
          [[ -z "$salt_hex" ]] || die "salt specified more than once"
          is_hex "$2" || die "--salt-hex expects an even-length hexadecimal string"
          salt_hex="''${2,,}"
          shift 2
          ;;
        --salt-file)
          [[ $# -ge 2 ]] || die "--salt-file requires an argument"
          [[ -z "$salt_hex" ]] || die "salt specified more than once"
          [[ -r "$2" ]] || die "cannot read salt file: $2"
          salt_hex="$(file_to_hex "$2")"
          shift 2
          ;;
        --info)
          [[ $# -ge 2 ]] || die "--info requires an argument"
          [[ -z "$user_info_hex" ]] || die "info specified more than once"
          user_info_hex="$(utf8_to_hex "$2")"
          shift 2
          ;;
        --info-hex)
          [[ $# -ge 2 ]] || die "--info-hex requires an argument"
          [[ -z "$user_info_hex" ]] || die "info specified more than once"
          is_hex "$2" || die "--info-hex expects an even-length hexadecimal string"
          user_info_hex="''${2,,}"
          shift 2
          ;;
        --length)
          [[ $# -ge 2 ]] || die "--length requires an argument"
          is_uint "$2" || die "--length expects a positive integer"
          (( $2 > 0 )) || die "--length expects a positive integer"
          user_length="$2"
          shift 2
          ;;
        --binary)
          [[ "$format" == "hex" ]] || die "--binary conflicts with --format $format"
          format="binary"
          shift
          ;;
        --otp-words)
          [[ $# -ge 2 ]] || die "--otp-words requires an argument"
          is_uint "$2" || die "--otp-words expects a positive integer"
          (( $2 > 0 )) || die "--otp-words expects a positive integer"
          otp_words="$2"
          shift 2
          ;;
        --otp-offset)
          [[ $# -ge 2 ]] || die "--otp-offset requires an argument"
          is_uint "$2" || die "--otp-offset expects a non-negative integer"
          otp_offset="$2"
          shift 2
          ;;
        --list-formats)
          list_formats
          exit 0
          ;;
        -h|--help)
          usage
          exit 0
          ;;
        --)
          shift
          break
          ;;
        *)
          die "unknown argument: $1"
          ;;
      esac
    done

    (( $# == 0 )) || die "unexpected positional arguments: $*"
    [[ -n "$salt_hex" ]] || die "one of --salt, --salt-hex, or --salt-file is required"
    [[ -n "$salt_hex" ]] || die "salt must not be empty"

    case "$format" in
      hex|binary)
        profile="raw"
        length="''${user_length:-32}"
        ;;
      ed25519)
        [[ -z "$user_length" ]] || die "--length is only supported with --format hex or --format binary"
        profile="ed25519"
        length=32
        ;;
      age)
        [[ -z "$user_length" ]] || die "--length is only supported with --format hex or --format binary"
        profile="age"
        length=32
        ;;
      *)
        die "unsupported --format: $format"
        ;;
    esac

    info_hex="$(utf8_to_hex "rpi-otp-derived-key:$profile")"
    if [[ -n "$user_info_hex" ]]; then
      info_hex+="00$user_info_hex"
    fi

    otp_hex="$(rpi-otp-private-key -l "$otp_words" -o "$otp_offset" | tr -d '[:space:]')"
    is_hex "$otp_hex" || die "rpi-otp-private-key did not return hexadecimal key material"

    expected_hex_length=$((otp_words * 8))
    (( ''${#otp_hex} == expected_hex_length )) || die \
      "expected $expected_hex_length hex digits from rpi-otp-private-key, got ''${#otp_hex}"

    [[ ! "$otp_hex" =~ ^0+$ ]] || die "OTP private key is not programmed (all zeros)"

    declare -a cmd=(
      openssl
      kdf
      -keylen "$length"
      -kdfopt digest:SHA256
      -kdfopt "hexkey:$otp_hex"
      -kdfopt "hexsalt:$salt_hex"
      -kdfopt "hexinfo:$info_hex"
    )

    if [[ "$format" == "binary" ]]; then
      cmd+=(-binary)
    fi

    cmd+=(HKDF)

    case "$format" in
      hex)
        derived_hex="$("''${cmd[@]}")"
        canonical_hex "$derived_hex"
        printf '\n'
        ;;
      binary)
        "''${cmd[@]}"
        ;;
      ed25519)
        derived_hex="$(canonical_hex "$("''${cmd[@]}")")"
        emit_ed25519_pem "$derived_hex"
        ;;
      age)
        derived_hex="$(canonical_hex "$("''${cmd[@]}")")"
        emit_age_identity "$derived_hex"
        ;;
    esac
  '';

  meta = with lib; {
    description = "Derive deterministic key material from the Raspberry Pi OTP private key using HKDF-SHA256";
    homepage = "https://github.com/nvmd/nixos-raspberrypi";
    license = licenses.mit;
    mainProgram = "rpi-otp-derived-key";
    platforms = [ "armv6l-linux" "armv7l-linux" "aarch64-linux" ];
  };
}
