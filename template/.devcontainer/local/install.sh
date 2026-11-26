#!/usr/bin/env bash
# Workspace-local feature: runs every executable in scripts.d/ (sorted) at image build.
set -euo pipefail

log() {
    echo "[local] $*"
}

err() {
    echo "[local] ERROR: $*" >&2
    exit 1
}

resolve_latest_openbao_version() {
    local releases_json version page=1
    local -a curl_args=(
        --fail
        --location
        --silent
        --show-error
        --retry 3
        -H "Accept: application/vnd.github+json"
    )

    if [ -n "${GITHUB_TOKEN:-}" ]; then
        curl_args+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
    fi

    while :; do
        releases_json="$(curl "${curl_args[@]}" \
            "https://api.github.com/repos/openbao/openbao/releases?per_page=20&page=${page}")" \
            || err "Unable to query OpenBao releases. Set 'version' to a published version and retry."

        version="$(printf '%s\n' "${releases_json}" | jq -r \
            --arg architecture "${architecture}" '
                [
                    .[]
                    | select(.draft == false and .prerelease == false)
                    | (.tag_name | ltrimstr("v")) as $version
                    | select(any(
                        .assets[]?;
                        .name == ("openbao_" + $version + "_linux_" + $architecture + ".tar.gz")
                      ))
                    | $version
                ]
                | first // empty
            ')"

        if [ -n "${version}" ]; then
            echo "${version}"
            return
        fi
        [ "$(printf '%s\n' "${releases_json}" | jq 'length')" -gt 0 ] || break
        page=$((page + 1))
    done

    err "No stable OpenBao release contains a Linux ${architecture} archive."
}

download_openbao() {
    local download_dir version archive_name release_url archive checksums_file expected_checksum extract_dir
    download_dir="$(mktemp -d)"
    # Expanded now: the local is gone when the EXIT trap runs
    trap "rm -rf '${download_dir}'" EXIT
    version="$(resolve_latest_openbao_version)"
    archive_name="openbao_${version}_linux_${architecture}.tar.gz"
    release_url="https://github.com/openbao/openbao/releases/download/v${version}"
    archive="${download_dir}/${archive_name}"
    checksums_file="${download_dir}/checksums.txt"

    log "Downloading OpenBao ${version} for Linux ${architecture}."
    curl --fail --location --silent --show-error --retry 5 --retry-all-errors \
        --output "${checksums_file}" "${release_url}/checksums.txt"
    curl --fail --location --silent --show-error --retry 5 --retry-all-errors \
        --output "${archive}" "${release_url}/${archive_name}"

    expected_checksum="$(awk -v archive="${archive_name}" '$2 == archive { print $1 }' "${checksums_file}")"
    [[ "${expected_checksum}" =~ ^[0-9a-fA-F]{64}$ ]] \
        || err "No valid checksum was published for ${archive_name}."
    printf '%s  %s\n' "${expected_checksum}" "${archive}" | sha256sum --check --status \
        || err "Checksum verification failed for ${archive_name}."

    extract_dir="${download_dir}/extract"
    install -d -m 0755 "${extract_dir}"
    tar -xzf "${archive}" -C "${extract_dir}"
    [ -x "${extract_dir}/bao" ] || err "The OpenBao release did not contain an executable named bao."
    install -m 0755 "${extract_dir}/bao" /usr/local/bin/bao
}

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl jq iputils-ping snap
# Chrome's runtime libraries and fonts. agent-browser and VHS download their own Chrome builds, and T3 previews
# need the same libraries; without them the browser exits before it starts.
apt-get install -y --no-install-recommends \
    libnss3 libatk1.0-0t64 libatk-bridge2.0-0t64 libatspi2.0-0t64 libcups2t64 \
    libdrm2 libgbm1 libpango-1.0-0 libcairo2 libxkbcommon0 libxcomposite1 \
    libxdamage1 libxfixes3 libxrandr2 libasound2t64 \
    fontconfig fonts-liberation fonts-noto-color-emoji
# ImageMagick hands PDF, PostScript and EPS input to Ghostscript.
apt-get install -y --no-install-recommends ghostscript

# Every bind mount target under the remote user's home, as in devcontainer.json's "mounts" (a test keeps them equal).
# Docker creates a missing parent of a mount target as root, which leaves the user unable to write beside the mount:
# agent-browser cannot take its session lock in ~/.agent-browser, for one. Create those parents now, as the user.
home_mount_targets=(
    .agent-browser/browsers
    .cache/Homebrew
    .cache/uv
    .claude
    .codex
    .gemini
    .local/share/charm
    .local/share/dagu
    .local/share/deck
    .local/share/gh/extensions
    .local/share/pnpm/store
    .local/share/uv/tools
    .local/state/git-operators
    .npm
    .npm-global
    .pi
    .t3/userdata
    mnemonic-vault
)

create_home_mount_parents() {
    local user="${_REMOTE_USER:-vscode}" home group target dir part
    home="$(getent passwd "${user}" | cut -d: -f6)"
    [ -n "${home}" ] || err "The remote user ${user} does not exist."
    group="$(id -gn "${user}")"
    for target in "${home_mount_targets[@]}"; do
        dir="${home}"
        # Each missing folder between the home and the mount target; folders that exist keep their owner and mode.
        for part in $(dirname -- "${target}" | tr / ' '); do
            [ "${part}" = . ] && continue
            dir="${dir}/${part}"
            [ -d "${dir}" ] || install -d -o "${user}" -g "${group}" -m 0755 "${dir}"
        done
    done
}

case "$(uname -m)" in
    x86_64|amd64) architecture=amd64 ;;
    arm64|aarch64) architecture=arm64 ;;
    *) err "Unsupported architecture: $(uname -m)." ;;
esac

create_home_mount_parents

# Run devcontainer local scripts
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
shopt -s nullglob
for script in scripts.d/*; do
    [ -f "$script" ] && [ -x "$script" ] || continue
    echo "local feature: running $script"
    "$script"
done
