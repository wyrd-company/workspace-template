#!/usr/bin/env bash
# postStartCommand: waits for the playbook, then proves that the Wyrwood sockets work.
# Takes the Xolotl key as <policy>/<name>. It discards the output of every check, so no
# token, key or server text reaches the job's log.
set -uo pipefail

xolotl_key="${1:?usage: check-provisioning.sh <key-policy>/<key-name>}"
# The playbook's first run clones every repository. This bound times the host, never a person.
wait_seconds="${PROVISIONING_WAIT_SECONDS:-1800}"
poll_seconds=2
PATH="${PATH}:/command"

fail() {
    echo "check-provisioning: $*" >&2
    failed=1
}

require_commands() {
    local name
    for name in "$@"; do
        command -v "${name}" >/dev/null || fail "${name} is not installed."
    done
    [ "${failed}" -eq 0 ]
}

# s6-rc holds its lock until the startup change ends, and refuses to list while it does. An
# empty list means the change has not begun. After it, ansible-setup is active only if the
# playbook succeeded: the Ansible feature has no other signal.
wait_for_playbook() {
    local deadline=$((SECONDS + wait_seconds)) active
    while [ "${SECONDS}" -lt "${deadline}" ]; do
        if active="$(s6-rc -a list 2>/dev/null)" && [ -n "${active}" ]; then
            if grep -qx ansible-setup <<<"${active}"; then
                return 0
            fi
            fail "the startup playbook failed. Its output is in the container's log."
            return 1
        fi
        sleep "${poll_seconds}"
    done
    fail "the container's startup did not end within ${wait_seconds} seconds."
    return 1
}

# The same read that Claude Code and Codex make for their key.
check_vault() {
    local socket="${BAO_ADDR#unix://}"
    if [ ! -S "${socket}" ]; then
        fail "${socket} is not a socket. Check the container's Wyrwood binding."
    elif ! bao token lookup >/dev/null 2>&1; then
        fail "${socket} has no working OpenBao token. Check the container's Wyrwood binding."
    elif ! bao kv get -field=api_key "kv/xolotl/keys/${xolotl_key}" >/dev/null 2>&1; then
        fail "cannot read Xolotl key ${xolotl_key} through ${socket}. Check that it was issued and that the binding's policies allow the read."
    fi
}

# Signing is what Git and SSH ask of this agent; listing a key does not prove that its Transit key signs.
check_ssh_agent() {
    local directory
    if [ ! -S "${SSH_AUTH_SOCK}" ]; then
        fail "${SSH_AUTH_SOCK} is not a socket. Check the container's Wyrwood binding."
        return
    fi
    directory="$(mktemp -d)" || { fail "cannot create a temporary directory."; return; }
    if ! ssh-add -L >"${directory}/keys.pub" 2>/dev/null; then
        fail "${SSH_AUTH_SOCK} offers no key. Check that the binding's policies name an SSH key."
    elif ! head -n 1 "${directory}/keys.pub" >"${directory}/key.pub" \
        || ! printf 'check-provisioning' \
        | ssh-keygen -Y sign -n check-provisioning -f "${directory}/key.pub" >/dev/null 2>&1; then
        fail "${SSH_AUTH_SOCK} did not sign with its key. Check that the binding's policies allow the signature."
    fi
    rm -rf -- "${directory:?}"
}

failed=0
require_commands bao grep head mktemp s6-rc ssh-add ssh-keygen || exit 1
wait_for_playbook || exit 1
check_vault
check_ssh_agent
[ "${failed}" -eq 0 ] || exit 1
echo "check-provisioning: the playbook ran, and vault.sock and ssh-agent.sock work."
