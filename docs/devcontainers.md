# Devcontainers

All devcontainers in the workspace use Wyrd Company's [Ubuntu base image](https://github.com/wyrd-company/devcontainers/tree/main/src/images/base-ubuntu). This image tracks the [upstream Microsoft devcontainers base](https://github.com/devcontainers/images/tree/main/src/base-ubuntu), but adds [S6-overlay](https://github.com/just-containers/s6-overlay) as the init process.

## Configuration

## Layout

```
/etc/devcontainer/                 # r/o mount of the workspace .devcontainer folder
│   ├── check-provisioning.sh      # postStartCommand: the playbook ran and the sockets work
│   └── local/scripts.d/           # the one writable part: scripts the local feature runs at image build
/etc/workspace/config.yml          # r/o mount of the workspace config.yml (the template answers)
/etc/claude-code/ /etc/codex/      # harness system settings, rendered by workspace-ansible
/etc/dagu/ /etc/trowel/ /etc/opentelemetry-collector/   # service configs, rendered by workspace-ansible
/home/vscode/                      # `vscode` profile: .claude, .codex, .pi, .t3/userdata are workspace mounts (state/)
│   ├── .agents/skills/            # clone of wyrd-company/skills (chezmoi); ~/.claude/skills/* symlink into it
│   ├── .local/share/dagu/         # Dagu state, a workspace mount (state/workflows)
│   └── mnemonic-vault/            # user-level vault, host clone shared by every workspace
/repos/                            # bare clones: memory.git, tasks.git, workflows.git
/tasks/                            # workspace tasks: orphan branch workspace/{workspace} of tasks
/workflows/main/                   # shared sub-dags and bin/ scripts: main of workflows (read only, PRs from worktrees/)
/workflows/local/                  # workspace workflows: orphan branch workspace/{workspace} of workflows
/workflows/worktrees/              # branches for changes: main/ for PRs to main, local/ for workspace/{workspace}
/workspace/                        # workspaceFolder: AGENTS.md, {workspace}.code-workspace
/run/wyrwood/                      # vault.sock and ssh-agent.sock from the host's Wyrwood agent
$WORKSPACE_HOME/docker/            # docker-outside-of-docker only: compose projects, at their host path
```

The bare clones and worktrees are created inside the container by workspace-ansible's `container.yml`, which
the Ansible feature runs at every start. They are cloned over HTTPS as `wyrd-automation[bot]`. Missing
workspace branches are created as orphan branches and pushed, and `/workflows/local` is initialized from the
toha template on `main`. Re-running it is a no-op for anything already set up, and resumes a worktree a
failed run left unfinished.

## T3Code Server

[T3Code server](https://t3.codes), a coding agent control plane, is [installed](https://github.com/wyrd-company/devcontainers/tree/main/src/features/t3code-server) on each devcontainer and runs as an S6-overlay service. This is the primary agentic access to the devcontainer.

## Reverse proxy

Nothing in the container publishes a port. The main server's Caddy reads the `caddy_*` labels in `runArgs` through this host's docker-socket-proxy and reaches the container over the shared `homelab` overlay network:

- Dagu at `workflows.<workspace>.<domain>`
- T3Code server at `t3.<workspace>.<domain>`

## Dagu 

[Dagu](https://dagu.sh) is [installed](https://github.com/wyrd-company/devcontainers/tree/main/src/features/dagu) on each devcontainer and runs as an S6-overlay service. Dagu provides scheduled or on-demand [workflows](https://github.com/boblangley/workflows) in order to perform repeatable work. It can create GitHub issues that will be managed by [Manifold](https://github.com/wyrd-company/manifold) or use a coding agent harness directly, as well as perform automatic programattic actions.

Examples of uses includes:

- Updating a fork default branch whenever a release tag is published upstream.
- Updating a fork PR branch, rebasing as upstream default branch is updated.
- Monitoring a PR for review comments from repository maintainers, and dispatching an agent to evaluate and address those comments.
- Monitoring an upstream PR opened by maintainers to prepare for upcoming integration work on a fork.
- Monitoring a GitHub issue for any reason and notifying or taking action.
- Performing merge conflict remediation and/or security audits on Renovate PRs.

## Docker

Devcontainers can, optionally, run [Docker](https://www.docker.com) server under S6-overlay, either as [Docker-in-Docker](https://github.com/wyrd-company/devcontainers/tree/main/src/features/docker-in-docker) or [Docker-out-of-Docker](https://github.com/wyrd-company/devcontainers/tree/main/src/features/docker-outside-of-docker). Docker-in-Docker is the normal case: its bind mounts resolve inside the devcontainer, so no host path is mirrored. Docker-outside-of-Docker is a special case for containers that help manage the host's Docker; it bind mounts the workspace's `docker/` folder at its host path, `$WORKSPACE_HOME/docker`, so the host daemon resolves the bind mounts of compose projects kept there. Toha creates the folder, and a backup ignores it, so a fresh clone needs it created again (see [Backups](workspaces.md#backups)).

## Skills

Shared agent skills are not mounted. The dotfiles clone [`wyrd-company/skills`](https://github.com/wyrd-company/skills) to `~/.agents/skills` (read natively by Pi and Codex) and symlink each skill into `~/.claude/skills/` for Claude Code. Changes to a skill are made on a branch in that clone and submitted as a PR.

## SSHD

Each container runs [`sshd` via S6-overlay](https://github.com/wyrd-company/devcontainers/tree/main/src/features/sshd) to allow, remote, authorized key access into the devcontainer.

## Wyrwood

[Wyrwood](https://wyrd.foo/docs/wyrwood/) delivers OpenBao secrets and SSH signing. The container holds no token, key, or secret file. The Wyrwood agent on the host publishes two sockets in `/run/wyrwood/containers/devcontainer-<workspace>` (the directory is named after the container), bind-mounted at `/run/wyrwood`:

- `vault.sock`: the OpenBao API (`VAULT_ADDR`/`BAO_ADDR`). The agent adds the container's own token, scoped by the Wyrwood policy bound to the container.
- `ssh-agent.sock`: an ssh-agent (`SSH_AUTH_SOCK`) whose keys are OpenBao Transit keys named in the policy.

Docker refuses to create the container while that directory is missing, and the agent creates it only when the container is bound. [Menagerie](https://github.com/wyrd-company/menagerie) does this for a workspace it creates: see [Provisioning](#provisioning). A workspace started by hand needs these steps before its first start:

1. On the host, create the directory owned by the agent's user: `sudo install -d -o wyrwood -g wyrwood -m 0700 /run/wyrwood/containers/devcontainer-<workspace>`. The agent applies the access group when it opens it.
2. `dcb up --skip-post-create` creates and starts the container without running its lifecycle commands, which need the sockets.
3. `docker stop devcontainer-<workspace>`.
4. Bind `devcontainer-<workspace>` to its policies in the Wyrwood UI, with the access group, the policies and the values of `customizations.menagerie`. The sockets appear in the directory.
5. Issue the Xolotl key.
6. `docker start devcontainer-<workspace>`.
7. `dcb run-user-commands` runs the lifecycle commands.

Steps 3 and 6 are a workaround. `dcb up` always starts the container, and the image's s6 startup services, such as
the Ansible feature's playbook run, start with it whatever `--skip-post-create` says. So the first start runs them
before the container is bound and they find no sockets; the start in step 6 runs them again with the sockets. Once
dcb can create a container without starting it
([devcontainer-builder#80](https://github.com/wyrd-company/devcontainer-builder/issues/80)), steps 2, 3 and 6 become
one create.

Later rebuilds keep the name, so the binding and directory carry over.

The policy's contract uses mount target `/run/wyrwood`. The access group is `1000` (the `vscode` user). On the host, the `wyrwood` user must be in the group with GID 1000.

## Xolotl

Claude Code (Anthropic models) and Codex CLI (every other model) talk to the [Xolotl](https://wyrd.foo/docs/xolotl/) gateway (`xolotl_url`). Neither holds an API key: `/etc/claude-code/managed-settings.json` (`apiKeyHelper`) and `/etc/codex/requirements.toml` (`auth.command`), rendered by workspace-ansible, run `bao kv get -field=api_key kv/xolotl/keys/<xolotl_key>` through `vault.sock`. `xolotl_key` is the Xolotl `<key policy>/<key name>` of the key. The template computes it from two parts:

- `xolotl_key_policy`, the one question. Its value is the host's key policy, which only this host's workspaces use. It has no template default, because a default cannot name a host. Set it once for each host: see [Per-host key policy](#per-host-key-policy).
- `xolotl_key_name`, which is the workspace name and is never asked.

`kv/xolotl` is the deployed Xolotl's KV v2 mount and prefix, in the `wyrwood` namespace it shares with Wyrwood.

## Provisioning

The rendered `.devcontainer/devcontainer.json` declares what the workspace needs from Wyrwood and Xolotl, under `customizations.menagerie`, in the form [Menagerie's provisioning declaration](https://github.com/wyrd-company/menagerie/blob/main/docs/specifications/provisioning-declaration.yml) defines. For a workspace called `sample`, on a host whose key policy is `host-sample`:

```jsonc
"runArgs": ["--name", "devcontainer-sample"],
"customizations": { "menagerie": {
  "wyrwood": { "accessGroup": 1000, "policies": ["workspace", "xolotl-client-key"], "values": {"xolotl_key_name": "sample"} },
  "xolotl": { "keyPolicy": "host-sample", "keyName": "sample" }
}}
```

Menagerie reads the container name from `runArgs`, issues the key, makes the binding and creates the container before its first start.

### Workspace names

A workspace name holds lowercase letters, digits, `_` and `-`, starts with a letter or digit, and has at most 63 characters, so that it can name a Xolotl key and be a Wyrwood policy value. Any other name stops the interview before a file is written, with a template error on `xolotl_key_name` that quotes the rule. Toha has no way to raise a message of a template's own, so the error ends in `invalid float literal`. No answer or configured default can replace the name.

### Start check

`postStartCommand` runs `.devcontainer/check-provisioning.sh` at every start that `dcb` makes, as the remote user. A failure fails `dcb up`, and so the Menagerie job that called it. In order, it:

1. Waits for the startup services to end, with a limit of 30 minutes (`PROVISIONING_WAIT_SECONDS`). `s6-rc -a list` refuses to list while the startup change runs. After it, the `ansible-setup` service is active only if the playbook succeeded. If it is not, the check fails, and the playbook's output is in the container's log.
2. Asks `vault.sock` for its token (`bao token lookup`) and reads the Xolotl key (`bao kv get`), as Claude Code and Codex do. A key that was not issued fails here. It ignores any `BAO_AGENT_ADDR` and `VAULT_AGENT_ADDR`, so that these reads go to the declared socket.
3. Asks `ssh-agent.sock` for its keys and signs with the first.

Each socket operation has a limit of 30 seconds (`PROVISIONING_SOCKET_SECONDS`). It reports each broken socket, and discards the output of each check, so no token, key or server text reaches a log. A start by the Docker restart policy, such as after a host reboot, does not run it.

## Host prerequisites

A workspace starts only on a host that has these. Menagerie reports the missing folders and networks in one message before it does anything else; it creates nothing outside the workspace folder.

### Shared folders

Folders under `/workspaces/.shared`, owned by the `vscode` user (UID 1000):

| Folder | Holds |
| --- | --- |
| `ca-certificates` | The host's root certificates, with `homelab-root.crt` |
| `caches/homebrew`, `caches/npm/global`, `caches/npm/local`, `caches/pnpm`, `caches/uv/packages`, `caches/uv/tools`, `caches/gh/extensions`, `caches/browsers` | Caches for every workspace |
| `caches/go-pkg` | Go cache, for a workspace with the `go` SDK |
| `caches/cargo` | Cargo cache, for a workspace with the `rust` SDK |
| `mnemonic-vault` | Clone of `mnemonic-vault`, branch `main` |

### `homelab` network

A Docker network called `homelab` that containers can attach to, shared with the main server's Caddy.

### Wyrwood policies

Two policies on the host's Wyrwood controller, each on the allowlist of Menagerie's operator key:

- `workspace` gives the container its mount target, `/run/wyrwood`, its SSH key, and what workspace-ansible and the dotfiles read.
- `xolotl-client-key` allows `read` on `kv/data/xolotl/keys/<key policy>/<xolotl_key_name>`, and nothing else. The key policy is fixed in the path, and the name comes from the binding's `xolotl_key_name` value, so that each workspace reads only its own key and cannot name a key of another host.

The policy name is fixed in the template and the path names one key policy, so one controller serves one key policy.

### Xolotl key policy

A Xolotl key policy, which only this host's workspaces use. A scoped key for this key policy, with the `keys` scope, lets Menagerie issue the workspaces' keys.

### Per-host key policy

Give the host's key policy as the default answer, in Toha's [`template-defaults`](https://wyrd.foo/docs/toha/configuration), so that no one types it for each workspace:

```yaml
template-defaults:
  "gh:wyrd-company/workspace-template":
    xolotl_key_policy: host-sample
```

The file is `/var/lib/menagerie/toha/config/config.yml` for Menagerie, and Toha's user configuration, `~/.config/toha/config.yml`, for the `toha` command. The key is the template's formal name, which `toha templates list` shows. Without this default, the interview asks for the key policy, and an answer can replace the default for one workspace.

## `vscode` user

The `vscode` user is created by the [base Ubuntu image](https://github.com/wyrd-company/devcontainers/tree/main/src/images/base-ubuntu) used by these devcontainers. This image tracks the [upstream Microsoft devcontainers base](https://github.com/devcontainers/images/tree/main/src/base-ubuntu), but adds [S6-overlay](https://github.com/just-containers/s6-overlay) as the init process.