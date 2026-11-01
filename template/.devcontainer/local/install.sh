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
apt-get install -y --no-install-recommends ca-certificates curl jq iputils-ping

case "$(uname -m)" in
    x86_64|amd64) architecture=amd64 ;;
    arm64|aarch64) architecture=arm64 ;;
    *) err "Unsupported architecture: $(uname -m)." ;;
esac

download_openbao

# Run devcontainer local scripts
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
shopt -s nullglob
for script in scripts.d/*; do
    [ -f "$script" ] && [ -x "$script" ] || continue
    echo "local feature: running $script"
    "$script"
done
