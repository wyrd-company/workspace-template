#!/usr/bin/env bash
# postStartCommand: waits for the playbook, then proves that the Wyrwood sockets work.
# Takes the Xolotl key as <policy>/<name>. It discards the output of every check, so no
# token, key or server text reaches the job's log.
set -uo pipefail

xolotl_key="${1:?usage: check-provisioning.sh <key-policy>/<key-name>}"
# The playbook's first run clones every repository. This bound times the host, never a person.
wait_seconds="${PROVISIONING_WAIT_SECONDS:-1800}"
poll_seconds=2
# A socket can accept a connection and never answer.
socket_seconds="${PROVISIONING_SOCKET_SECONDS:-30}"
timed_out=124
PATH="${PATH}:/command"

# These reads must prove the declared socket, so no other address may take their place.
unset BAO_AGENT_ADDR VAULT_AGENT_ADDR
export VAULT_ADDR="${BAO_ADDR}"

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

# Runs one socket operation under the bound, with its output discarded.
bounded() {
    timeout "${socket_seconds}" "$@" >/dev/null 2>&1
}

# Reports a failed operation on a socket: its exit status decides between the two messages.
fail_socket() {
    local socket="$1" status="$2" message="$3"
    if [ "${status}" -eq "${timed_out}" ]; then
        fail "${socket} did not answer within ${socket_seconds} seconds. Check the Wyrwood agent."
    else
        fail "${message}"
    fi
}

# The same read that Claude Code and Codex make for their key.
check_vault() {
    local socket="${BAO_ADDR#unix://}" status
    if [ ! -S "${socket}" ]; then
        fail "${socket} is not a socket. Check the container's Wyrwood binding."
        return
    fi
    bounded bao token lookup
    status=$?
    if [ "${status}" -ne 0 ]; then
        fail_socket "${socket}" "${status}" \
            "${socket} has no working OpenBao token. Check the Wyrwood agent and the container's binding."
        return
    fi
    bounded bao kv get -field=api_key "kv/xolotl/keys/${xolotl_key}"
    status=$?
    if [ "${status}" -ne 0 ]; then
        fail_socket "${socket}" "${status}" \
            "cannot read Xolotl key ${xolotl_key} through ${socket}. Check that it was issued and that the binding's policies allow the read."
    fi
}

# Signing is what Git and SSH ask of this agent; listing a key does not prove that its Transit key signs.
check_ssh_agent() {
    local directory status
    if [ ! -S "${SSH_AUTH_SOCK}" ]; then
        fail "${SSH_AUTH_SOCK} is not a socket. Check the container's Wyrwood binding."
        return
    fi
    directory="$(mktemp -d)" || { fail "cannot create a temporary directory."; return; }
    timeout "${socket_seconds}" ssh-add -L >"${directory}/keys.pub" 2>/dev/null
    status=$?
    if [ "${status}" -ne 0 ]; then
        # ssh-add exits 1 for an empty agent and for a failed request. Only an empty agent prints this.
        if [ "${status}" -eq 1 ] && grep -qx 'The agent has no identities.' "${directory}/keys.pub"; then
            fail "${SSH_AUTH_SOCK} offers no key. Check that the binding's policies name an SSH key."
        else
            fail_socket "${SSH_AUTH_SOCK}" "${status}" \
                "${SSH_AUTH_SOCK} does not answer as an ssh-agent. Check the Wyrwood agent."
        fi
    else
        head -n 1 "${directory}/keys.pub" >"${directory}/key.pub"
        printf 'check-provisioning' \
            | timeout "${socket_seconds}" ssh-keygen -Y sign -n check-provisioning -f "${directory}/key.pub" >/dev/null 2>&1
        status=$?
        if [ "${status}" -ne 0 ]; then
            fail_socket "${SSH_AUTH_SOCK}" "${status}" \
                "${SSH_AUTH_SOCK} did not sign with its key. Check that the binding's policies allow the signature."
        fi
    fi
    rm -rf -- "${directory:?}"
}

failed=0
require_commands bao grep head mktemp s6-rc ssh-add ssh-keygen timeout || exit 1
wait_for_playbook || exit 1
check_vault
check_ssh_agent
[ "${failed}" -eq 0 ] || exit 1
echo "check-provisioning: the playbook ran, and vault.sock and ssh-agent.sock work."
