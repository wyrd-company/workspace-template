#!/usr/bin/env bash
# Checks the provisioning block and check-provisioning.sh. Needs toha, dcb, a Docker daemon for
# dcb, bao, python3 with jsonschema, and openssh-client on PATH. Set MENAGERIE_SCHEMA to
# Menagerie's docs/specifications/assets/provisioning-declaration/menagerie-customization.schema.json.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema="${MENAGERIE_SCHEMA:?set MENAGERIE_SCHEMA to the Menagerie customization schema}"
scratch="$(mktemp -d)"
canary="canary-value-$$"
vault_pid=""
agent_pid=""
failures=0
checks=0

cleanup() {
    [ -z "${vault_pid}" ] || kill "${vault_pid}" 2>/dev/null
    [ -z "${agent_pid}" ] || kill "${agent_pid}" 2>/dev/null
    rm -rf -- "${scratch:?}"
}
trap cleanup EXIT

export XDG_CONFIG_HOME="${scratch}/toha/config" XDG_DATA_HOME="${scratch}/toha/data"
export XDG_STATE_HOME="${scratch}/toha/state" XDG_CACHE_HOME="${scratch}/toha/cache"
mkdir -p "${XDG_CONFIG_HOME}/toha" "${scratch}/targets"

pass() { checks=$((checks + 1)); echo "ok   - $1"; }
miss() { checks=$((checks + 1)); failures=$((failures + 1)); echo "FAIL - $1: $2"; }

# ---- Render -----------------------------------------------------------------------------------

answers() {
    printf '{"template":"%s","answers":%s}' "${repo}" "$1" >"${scratch}/answers.json"
}

render() {
    answers "$2"
    toha apply "${repo}" "${scratch}/targets/$1" --answers "${scratch}/answers.json" 2>&1
}

jq_block='.configuration.customizations.menagerie'

test_render_matches_schema() {
    local output block
    output="$(render sample '{"xolotl_key_policy":"host-sample"}')"
    [ "$(jq -r .status <<<"${output}")" = applied ] || { miss "render sample" "${output}"; return; }
    if ! block="$(dcb read-configuration --workspace-folder "${scratch}/targets/sample" | jq -cS "${jq_block}")"; then
        miss "dcb reads the rendered definition" "dcb failed"
        return
    fi
    if [ "${block}" = '{"wyrwood":{"accessGroup":1000,"policies":["workspace","xolotl-client-key"],"values":{"xolotl_key_name":"sample"}},"xolotl":{"keyName":"sample","keyPolicy":"host-sample"}}' ]; then
        pass "render_block_equals_declaration"
    else
        miss "render_block_equals_declaration" "${block}"
    fi
    if python3 -c 'import json, sys, jsonschema; jsonschema.validate(json.loads(sys.argv[1]), json.load(open(sys.argv[2])))' \
        "${block}" "${schema}"; then
        pass "render_block_valid_against_schema"
    else
        miss "render_block_valid_against_schema" "${block}"
    fi
    if grep -qx 'xolotl_key: host-sample/sample' "${scratch}/targets/sample/config.yml"; then
        pass "render_config_keeps_xolotl_key"
    else
        miss "render_config_keeps_xolotl_key" "$(cat "${scratch}/targets/sample/config.yml")"
    fi
    if dcb read-configuration --workspace-folder "${scratch}/targets/sample" | jq -r '.configuration.runArgs | join(" ")' \
        | grep -q -- '--name devcontainer-sample'; then
        pass "render_container_name_in_run_args"
    else
        miss "render_container_name_in_run_args" "no --name devcontainer-sample"
    fi
    if [ "$(dcb read-configuration --workspace-folder "${scratch}/targets/sample" | jq -r .configuration.postStartCommand)" \
        = 'bash /etc/devcontainer/check-provisioning.sh host-sample/sample' ] \
        && [ -f "${scratch}/targets/sample/.devcontainer/check-provisioning.sh" ]; then
        pass "render_runs_check_at_post_start"
    else
        miss "render_runs_check_at_post_start" "no such postStartCommand or file"
    fi
}

test_render_refuses_workspace_name() {
    local name output
    for name in Upper.Case has.dot UPPER -leading _leading 'has space' "$(printf 'a%.0s' {1..64})"; do
        output="$(render "./${name}" '{"xolotl_key_policy":"host-sample"}')"
        if [ "$(jq -r .kind <<<"${output}")" = render ] && [ ! -e "${scratch}/targets/${name}" ] \
            && grep -q 'workspace_name_must_be_lowercase' <<<"${output}"; then
            pass "render_refuses_workspace_name ${name:0:20}"
        else
            miss "render_refuses_workspace_name ${name:0:20}" "${output}"
        fi
    done
    output="$(render "$(printf 'a%.0s' {1..63})" '{"xolotl_key_policy":"host-sample"}')"
    if [ "$(jq -r .status <<<"${output}")" = applied ]; then
        pass "render_accepts_63_character_workspace"
    else
        miss "render_accepts_63_character_workspace" "${output}"
    fi
}

test_render_key_policy() {
    local output
    output="$(render no-policy '{}')"
    if [ "$(jq -r .status <<<"${output}")" = questions ] && [ ! -e "${scratch}/targets/no-policy" ]; then
        pass "render_asks_for_key_policy_without_default"
    else
        miss "render_asks_for_key_policy_without_default" "${output}"
    fi
    output="$(render bad-policy '{"xolotl_key_policy":"host/sample"}')"
    if [ "$(jq -r .status <<<"${output}")" != applied ] && [ ! -e "${scratch}/targets/bad-policy" ]; then
        pass "render_refuses_key_policy_with_slash"
    else
        miss "render_refuses_key_policy_with_slash" "${output}"
    fi
    printf 'template-defaults:\n  "%s":\n    xolotl_key_policy: host-configured\n' "${repo}" \
        >"${XDG_CONFIG_HOME}/toha/config.yml"
    render configured '{}' >/dev/null
    if grep -qx 'xolotl_key: host-configured/configured' "${scratch}/targets/configured/config.yml" 2>/dev/null; then
        pass "render_takes_key_policy_from_template_defaults"
    else
        miss "render_takes_key_policy_from_template_defaults" "no host-configured key"
    fi
    printf 'template-defaults:\n  "%s":\n    xolotl_key_name: other\n    xolotl_key_policy: host-configured\n' "${repo}" \
        >"${XDG_CONFIG_HOME}/toha/config.yml"
    render fixed-name '{}' >/dev/null
    if grep -qx 'xolotl_key: host-configured/fixed-name' "${scratch}/targets/fixed-name/config.yml" 2>/dev/null; then
        pass "render_key_name_ignores_configured_default"
    else
        miss "render_key_name_ignores_configured_default" "the name is not the workspace name"
    fi
    output="$(render Bad.Configured '{}')"
    if [ ! -e "${scratch}/targets/Bad.Configured" ]; then
        pass "render_configured_default_does_not_admit_bad_name"
    else
        miss "render_configured_default_does_not_admit_bad_name" "${output}"
    fi
    rm -f "${XDG_CONFIG_HOME}/toha/config.yml"
}

# ---- check-provisioning.sh --------------------------------------------------------------------

check="${repo}/template/.devcontainer/check-provisioning.sh"
sockets="${scratch}/sockets"
stubs="${scratch}/stubs"
mkdir -p "${sockets}" "${stubs}"

# s6-rc reads each answer from a line of the script file, then repeats the last.
# "busy" fails as the real one does while the startup change holds its lock.
cat >"${stubs}/s6-rc" <<'STUB'
#!/usr/bin/env bash
[ "$*" = '-a list' ] || { echo "s6-rc stub: unexpected arguments: $*" >&2; exit 100; }
script="${S6_SCRIPT:?}"
count_file="${script}.count"
count=$(($(cat "${count_file}" 2>/dev/null || echo 0) + 1))
echo "${count}" >"${count_file}"
total=$(wc -l <"${script}")
line=$(sed -n "$((count < total ? count : total))p" "${script}")
case "${line}" in
    busy) echo 's6-rc: fatal: unable to take locks: Resource busy' >&2; exit 111 ;;
    empty) exit 0 ;;
    *) tr ' ' '\n' <<<"${line}" ;;
esac
STUB
chmod +x "${stubs}/s6-rc"

start_vault() {
    echo ok >"${scratch}/vault-mode"
    python3 "${repo}/tests/fake-vault.py" "${sockets}/vault.sock" "${scratch}/vault-mode" "${scratch}/vault.log" "${canary}" &
    vault_pid=$!
    for _ in {1..50}; do
        [ -S "${sockets}/vault.sock" ] && return
        sleep 0.1
    done
    echo "fake vault did not start" >&2
    exit 1
}

start_agent() {
    ssh-keygen -q -t ed25519 -N '' -f "${scratch}/agent-key"
    eval "$(ssh-agent -a "${sockets}/ssh-agent.sock")" >/dev/null
    agent_pid="${SSH_AGENT_PID}"
    SSH_AUTH_SOCK="${sockets}/ssh-agent.sock" ssh-add -q "${scratch}/agent-key"
}

# Runs the script with one s6-rc answer per argument; sets rc and output.
run_check() {
    printf '%s\n' "$@" >"${scratch}/s6-script"
    rm -f "${scratch}/s6-script.count"
    output="$(env PATH="${stubs}:${PATH}" S6_SCRIPT="${scratch}/s6-script" \
        BAO_ADDR="unix://${sockets}/vault.sock" VAULT_ADDR="unix://${sockets}/vault.sock" \
        SSH_AUTH_SOCK="${SSH_SOCKET:-${sockets}/ssh-agent.sock}" PROVISIONING_WAIT_SECONDS="${WAIT:-20}" \
        PROVISIONING_SOCKET_SECONDS="${SOCKET_WAIT:-30}" ${EXTRA_ENV:-} \
        bash "${check}" host-sample/sample 2>&1)"
    rc=$?
}

expect() {
    local name="$1" want_rc="$2" want_text="$3"
    if [ "${rc}" -ne "${want_rc}" ]; then
        miss "${name}" "exit ${rc}, want ${want_rc}: ${output}"
    elif ! grep -qF -- "${want_text}" <<<"${output}"; then
        miss "${name}" "no '${want_text}' in: ${output}"
    elif grep -qF -- "${canary}" <<<"${output}"; then
        miss "${name}" "the output holds the secret: ${output}"
    else
        pass "${name}"
    fi
}

# A socket with no listener: it exists, and a connection to it fails.
dead_socket() {
    python3 -c 'import socket, sys; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$1"
}

# Fails the check when a bound of 1 second took much longer than that.
expect_bounded() {
    local name="$1" text="$2" started="$3"
    if [ "$((SECONDS - started))" -gt 10 ]; then
        miss "${name}" "a bound of 1 second took $((SECONDS - started)) seconds"
    else
        expect "${name}" 1 "${text}"
    fi
}

active='s6rc-oneshot-runner ansible-setup fix-attrs legacy-cont-init'
down='s6rc-oneshot-runner fix-attrs legacy-cont-init'

test_check() {
    start_vault
    start_agent

    : >"${scratch}/vault.log"
    run_check "${active}"
    expect check_passes_when_all_work 0 'vault.sock and ssh-agent.sock work'
    if grep -qx '/v1/kv/data/xolotl/keys/host-sample/sample' "${scratch}/vault.log"; then
        pass "check_reads_the_declared_key"
    else
        miss "check_reads_the_declared_key" "$(cat "${scratch}/vault.log")"
    fi

    run_check busy busy empty "${active}"
    expect check_waits_while_startup_runs 0 'work'
    if [ "$(cat "${scratch}/s6-script.count")" = 4 ]; then
        pass "check_polled_until_startup_ended"
    else
        miss "check_polled_until_startup_ended" "polled $(cat "${scratch}/s6-script.count") times"
    fi

    run_check busy "${down}"
    expect check_fails_when_playbook_failed 1 'the startup playbook failed'

    local started="${SECONDS}"
    WAIT=1 run_check busy
    if [ "$((SECONDS - started))" -gt 10 ]; then
        miss check_fails_at_the_bound "a bound of 1 second took $((SECONDS - started)) seconds"
    else
        expect check_fails_at_the_bound 1 'did not end within 1 seconds'
    fi

    echo no-token >"${scratch}/vault-mode"
    run_check "${active}"
    expect check_fails_without_token 1 'no working OpenBao token'

    echo no-key >"${scratch}/vault-mode"
    run_check "${active}"
    expect check_fails_without_issued_key 1 'cannot read Xolotl key host-sample/sample'

    echo server-error >"${scratch}/vault-mode"
    run_check "${active}"
    expect check_keeps_server_text_out 1 'cannot read Xolotl key'
    echo ok >"${scratch}/vault-mode"

    # A dead declared socket, and a working address that must not stand in for it.
    python3 "${repo}/tests/fake-vault.py" "${sockets}/other-vault.sock" "${scratch}/vault-mode" "${scratch}/other.log" "${canary}" &
    other_pid=$!
    for _ in {1..50}; do
        [ -S "${sockets}/other-vault.sock" ] && break
        sleep 0.1
    done
    mv "${sockets}/vault.sock" "${sockets}/vault.saved"
    dead_socket "${sockets}/vault.sock"
    EXTRA_ENV="BAO_AGENT_ADDR=unix://${sockets}/other-vault.sock VAULT_AGENT_ADDR=unix://${sockets}/other-vault.sock" run_check "${active}"
    expect check_ignores_alternate_agent_address 1 'no working OpenBao token'
    kill "${other_pid}" 2>/dev/null
    rm -f "${sockets}/vault.sock"
    mv "${sockets}/vault.saved" "${sockets}/vault.sock"

    echo stall >"${scratch}/vault-mode"
    started="${SECONDS}"
    SOCKET_WAIT=1 run_check "${active}"
    expect_bounded check_bounds_stalled_vault 'vault.sock did not answer within 1 seconds' "${started}"
    echo ok >"${scratch}/vault-mode"

    python3 -c 'import socket, sys, time; s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(); c = [s.accept() for _ in range(9)]; time.sleep(600)' \
        "${sockets}/stalled.sock" &
    stalled_pid=$!
    for _ in {1..50}; do
        [ -S "${sockets}/stalled.sock" ] && break
        sleep 0.1
    done
    started="${SECONDS}"
    SSH_SOCKET="${sockets}/stalled.sock" SOCKET_WAIT=1 run_check "${active}"
    expect_bounded check_bounds_stalled_agent 'stalled.sock did not answer within 1 seconds' "${started}"
    kill "${stalled_pid}" 2>/dev/null

    python3 "${repo}/tests/stalling-agent.py" "${sockets}/no-sign.sock" "${scratch}/agent-key.pub" &
    stalled_pid=$!
    for _ in {1..50}; do
        [ -S "${sockets}/no-sign.sock" ] && break
        sleep 0.1
    done
    started="${SECONDS}"
    SSH_SOCKET="${sockets}/no-sign.sock" SOCKET_WAIT=1 run_check "${active}"
    expect_bounded check_bounds_stalled_signature 'no-sign.sock did not answer within 1 seconds' "${started}"
    kill "${stalled_pid}" 2>/dev/null

    dead_socket "${sockets}/dead.sock"
    SSH_SOCKET="${sockets}/dead.sock" run_check "${active}"
    expect check_names_dead_agent_socket 1 'does not answer as an ssh-agent'

    SSH_SOCKET="${sockets}/missing.sock" run_check "${active}"
    expect check_fails_without_agent_socket 1 'missing.sock is not a socket'

    SSH_SOCKET="${sockets}/ssh-agent.sock" SSH_AUTH_SOCK="${sockets}/ssh-agent.sock" ssh-add -q -D
    run_check "${active}"
    expect check_fails_when_agent_has_no_key 1 'offers no key'

    # A key held for confirmation lists but does not sign without a person to confirm it.
    SSH_AUTH_SOCK="${sockets}/ssh-agent.sock" ssh-add -q -c "${scratch}/agent-key"
    SSH_ASKPASS=/bin/false run_check "${active}"
    expect check_fails_when_agent_cannot_sign 1 'did not sign with its key'

    # Both sockets broken: the job's console names both.
    SSH_AUTH_SOCK="${sockets}/ssh-agent.sock" ssh-add -q -D
    echo no-token >"${scratch}/vault-mode"
    run_check "${active}"
    if grep -q 'no working OpenBao token' <<<"${output}" && grep -q 'offers no key' <<<"${output}"; then
        pass "check_reports_every_broken_socket"
    else
        miss "check_reports_every_broken_socket" "${output}"
    fi

    mv "${sockets}/vault.sock" "${sockets}/vault.moved"
    run_check "${active}"
    expect check_fails_without_vault_socket 1 'vault.sock is not a socket'
    mv "${sockets}/vault.moved" "${sockets}/vault.sock"
}

test_render_matches_schema
test_render_refuses_workspace_name
test_render_key_policy
test_check

if [ "${checks}" -eq 0 ]; then
    echo "FAIL - no check ran"
    exit 1
fi
echo "${checks} checks, ${failures} failed"
[ "${failures}" -eq 0 ]
