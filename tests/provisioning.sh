#!/usr/bin/env bash
# Checks the provisioning block. Needs toha, dcb, a Docker daemon for dcb, jq, and python3 with
# jsonschema on PATH. Set MENAGERIE_SCHEMA to
# Menagerie's docs/specifications/assets/provisioning-declaration/menagerie-customization.schema.json.
set -uo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
schema="${MENAGERIE_SCHEMA:?set MENAGERIE_SCHEMA to the Menagerie customization schema}"
scratch="$(mktemp -d)"
failures=0
checks=0

cleanup() {
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
    if ! grep -Eq '^  - id: (xolotl_key_policy|xolotl_key_name)$' "${repo}/template.yml"; then
        pass "render_has_no_removed_key_questions"
    else
        miss "render_has_no_removed_key_questions" "obsolete interview field found"
    fi
    output="$(render sample '{"remote":""}')"
    [ "$(jq -r .status <<<"${output}")" = applied ] || { miss "render sample" "${output}"; return; }
    if ! block="$(dcb read-configuration --workspace-folder "${scratch}/targets/sample" | jq -cS "${jq_block}")"; then
        miss "dcb reads the rendered definition" "dcb failed"
        return
    fi
    if [ "${block}" = '{"wyrwood":{"accessGroup":1000}}' ]; then
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
    if grep -Fxq "xolotl_key: \"{{ lookup('env', 'MENAGERIE_XOLOTL_KEY') }}\"" "${scratch}/targets/sample/config.yml"; then
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
    # Nothing may check the container at start: its tools come with the dotfiles, after the start.
    if [ "$(dcb read-configuration --workspace-folder "${scratch}/targets/sample" | jq -r .configuration.postStartCommand)" = null ] \
        && [ ! -e "${scratch}/targets/sample/.devcontainer/check-provisioning.sh" ]; then
        pass "render_has_no_start_check"
    else
        miss "render_has_no_start_check" "a postStartCommand or check-provisioning.sh is rendered"
    fi
}

test_render_refuses_workspace_name() {
    local name output
    for name in Upper.Case has.dot UPPER -leading _leading 'has space' "$(printf 'a%.0s' {1..64})"; do
        output="$(render "./${name}" '{}')"
        if [ "$(jq -r .kind <<<"${output}")" = render ] && [ ! -e "${scratch}/targets/${name}" ] \
            && grep -q 'workspace_name_must_be_lowercase' <<<"${output}"; then
            pass "render_refuses_workspace_name ${name:0:20}"
        else
            miss "render_refuses_workspace_name ${name:0:20}" "${output}"
        fi
    done
    output="$(render "$(printf 'a%.0s' {1..63})" '{"remote":""}')"
    if [ "$(jq -r .status <<<"${output}")" = applied ]; then
        pass "render_accepts_63_character_workspace"
    else
        miss "render_accepts_63_character_workspace" "${output}"
    fi
}

test_render_matches_schema
test_render_refuses_workspace_name

if [ "${checks}" -eq 0 ]; then
    echo "FAIL - no check ran"
    exit 1
fi
echo "${checks} checks, ${failures} failed"
[ "${failures}" -eq 0 ]
