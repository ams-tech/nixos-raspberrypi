#! @bash@/bin/sh -e

shopt -s nullglob

export PATH=/empty:@path@

usage() {
    echo "usage: $0 [-i] -f <firmware-dir> -b <boot-dir> -c <path-to-default-configuration>" >&2
    exit 1
}

default=               # Default configuration, needed for extlinux
runInstallHook=0
boottarget=
fwtarget=

declare -A initrdSecretsAppended

echo "uboot-builder: $*"
while getopts "ic:b:f:" opt; do
    case "$opt" in
        i) runInstallHook=1 ;;
        c) default="$OPTARG" ;;
        b) boottarget="$OPTARG" ;;
        f) fwtarget="$OPTARG" ;;
        \?) usage ;;
    esac
done

if [ -z "$boottarget" ] && [ -z "$fwtarget" ]; then
    echo "Error: at least one of \`-b <boot-dir>\` and \`-f <firmware-dir>\` must be set"
    usage
fi

if [ "$runInstallHook" = "1" ]; then
    pre_install_hook=@preInstallHook@
    if [ -n "$pre_install_hook" ]; then
        "$pre_install_hook" "$default" "$boottarget" "$fwtarget"
    fi
fi

# # process arguments for this builder, then pass the remainder to extlinux'
# while getopts ":f:" opt; do
#     case "$opt" in
#         f) target="$OPTARG" ;;
#         *) ;;
#     esac
# done
# shift $((OPTIND-2))
# extlinuxBuilderExtraArgs="$@"

copyForced() {
    local src="$1"
    local dst="$2"
    cp $src $dst.tmp
    mv $dst.tmp $dst
}

cleanName() {
    local path="$1"
    echo "$path" | sed 's|^/nix/store/||' | sed 's|/|-|g'
}

loadInitrdSecretsScript() {
    local generationPath="$1"
    local bootspec="$generationPath/boot.json"

    if ! [ -e "$bootspec" ]; then
        return 0
    fi

    jq -r '."org.nixos.bootspec.v1".initrdSecrets // empty' "$bootspec"
}

appendInitrdSecrets() {
    local generationPath="$1"
    local initrdPath="$2"
    local generationName="$3"

    if ! [ -e "$initrdPath" ] || [ "${initrdSecretsAppended["$initrdPath"]}" = 1 ]; then
        return 0
    fi

    local initrdSecrets
    initrdSecrets="$(loadInitrdSecretsScript "$generationPath")"

    if [ -z "$initrdSecrets" ]; then
        initrdSecretsAppended["$initrdPath"]=1
        return 0
    fi

    local initrdDir
    local tmpPath
    initrdDir="$(dirname "$initrdPath")"
    tmpPath="$(mktemp "$initrdDir/.initrd.tmp.XXXXXX")"

    cp "$initrdPath" "$tmpPath"
    if "$initrdSecrets" "$tmpPath"; then
        mv "$tmpPath" "$initrdPath"
        initrdSecretsAppended["$initrdPath"]=1
        return 0
    fi

    rm -f "$tmpPath"

    if [ "$generationName" = "default" ]; then
        echo "failed to create initrd secrets!" >&2
        exit 1
    fi

    echo "warning: failed to create initrd secrets for \"$generationName\", an older generation" >&2
    echo "note: this is normal after having removed or renamed a file in \`boot.initrd.secrets\`" >&2
}

appendGenerationInitrdSecrets() {
    local generationPath="$1"
    local generationName="$2"
    local target="$3"

    if ! [ -e "$generationPath/initrd" ]; then
        return 0
    fi

    local initrdSource
    local initrdPath
    initrdSource="$(readlink -f "$generationPath/initrd")"
    initrdPath="$target/nixos/$(cleanName "$initrdSource")"

    appendInitrdSecrets "$generationPath" "$initrdPath" "$generationName"
}

appendAllInitrdSecrets() {
    local defaultGenerationPath="$1"
    local target="$2"

    appendGenerationInitrdSecrets "$defaultGenerationPath" default "$target"

    for generation in $(
        (cd /nix/var/nix/profiles && ls -d system-*-link) \
        | sed 's/system-\([0-9]\+\)-link/\1/' \
        | sort -n -r); do
        link=/nix/var/nix/profiles/system-$generation-link
        appendGenerationInitrdSecrets "$link" "${generation}-default" "$target"
        for specialisation in $(
            ls /nix/var/nix/profiles/system-$generation-link/specialisation \
            | sort -n -r); do
            link=/nix/var/nix/profiles/system-$generation-link/specialisation/$specialisation
            appendGenerationInitrdSecrets "$link" "${generation}-${specialisation}" "$target"
        done
    done
}

if [ -n "$fwtarget" ]; then
    @firmwareBuilder@ -c $default -d $fwtarget

    echo "copying u-boot binary..."
    copyForced @uboot@/u-boot.bin $fwtarget/@ubootBinName@
fi

if [ -n "$boottarget" ]; then
    echo "generating extlinux configuration..."
    @extlinuxConfBuilder@ -c $default -d $boottarget
    appendAllInitrdSecrets "$default" "$boottarget"
fi

msg=""
if [ -n "$fwtarget" ]; then
    msg="uboot"
fi
if [ -n "$boottarget" ]; then
    msg="$msg+extlinux"
fi
echo "$msg bootloader installed"
