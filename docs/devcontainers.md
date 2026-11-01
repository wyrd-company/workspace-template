# Devcontainers

All devcontainers in the workspace use Wyrd Company's [Ubuntu base image](https://github.com/wyrd-company/devcontainers/tree/main/src/images/base-ubuntu). This image tracks the [upstream Microsoft devcontainers base](https://github.com/devcontainers/images/tree/main/src/base-ubuntu), but adds [S6-overlay](https://github.com/just-containers/s6-overlay) as the init process.

## Configuration

## Layout

```
/etc/devcontainer/                 # r/o mount of the workspace .devcontainer folder
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
/workflows/local/                  # workspace workflows: orphan branch {workspace} of workflows
/workflows/worktrees/              # branches for changes: main/ for PRs to main, local/ for {workspace}
/workspace/                        # workspaceFolder: AGENTS.md, {workspace}.code-workspace
/run/wyrwood/                      # vault.sock and ssh-agent.sock from the host's Wyrwood agent
/opt/docker/{workspace}/           # docker-outside-of-docker only: host mirror of compose projects
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

Devcontainers can, optionally, run [Docker](https://www.docker.com) server under S6-overlay, either as [Docker-in-Docker](https://github.com/wyrd-company/devcontainers/tree/main/src/features/docker-in-docker) or [Docker-out-of-Docker](https://github.com/wyrd-company/devcontainers/tree/main/src/features/docker-outside-of-docker). Docker-in-Docker is the normal case: its bind mounts resolve inside the devcontainer, so no host path is mirrored. Docker-outside-of-Docker is a special case for containers that help manage the host's Docker; it bind mounts the host's compose projects, `/opt/docker`, at the same path so the host daemon resolves their bind mounts.

## Skills

Shared agent skills are not mounted. The dotfiles clone [`wyrd-company/skills`](https://github.com/wyrd-company/skills) to `~/.agents/skills` (read natively by Pi and Codex) and symlink each skill into `~/.claude/skills/` for Claude Code. Changes to a skill are made on a branch in that clone and submitted as a PR.

## SSHD

Each container runs [`sshd` via S6-overlay](https://github.com/wyrd-company/devcontainers/tree/main/src/features/sshd) to allow, remote, authorized key access into the devcontainer.

## Wyrwood

[Wyrwood](https://wyrd.foo/docs/wyrwood/) delivers OpenBao secrets and SSH signing. The container holds no token, key, or secret file. The Wyrwood agent on the host publishes two sockets in `/run/wyrwood/containers/devcontainer-<workspace>` (the directory is named after the container), bind-mounted at `/run/wyrwood`:

- `vault.sock`: the OpenBao API (`VAULT_ADDR`/`BAO_ADDR`). The agent adds the container's own token, scoped by the Wyrwood policy bound to the container.
- `ssh-agent.sock`: an ssh-agent (`SSH_AUTH_SOCK`) whose keys are OpenBao Transit keys named in the policy.

Docker refuses to create the container while that directory is missing, and the agent creates it only when the container is bound. For the first start:

1. On the host, create the directory owned by the agent's user: `sudo install -d -o wyrwood -g wyrwood -m 0700 /run/wyrwood/containers/devcontainer-<workspace>`. The agent applies the access group when it opens it.
2. `dcb up --skip-post-create` creates and starts the container without running its lifecycle commands, which need the sockets.
3. Bind `devcontainer-<workspace>` to its policies in the Wyrwood UI. The sockets appear in the directory.
4. `dcb run-user-commands` runs the lifecycle commands.

Later rebuilds keep the name, so the binding and directory carry over.

The policy's contract uses mount target `/run/wyrwood` and access group `1000` (the `vscode` user). On the host, the `wyrwood` user must be in the group with GID 1000.

## Xolotl

Claude Code (Anthropic models) and Codex CLI (every other model) talk to the [Xolotl](https://wyrd.foo/docs/xolotl/) gateway (`xolotl_url`). Neither holds an API key: `/etc/claude-code/managed-settings.json` (`apiKeyHelper`) and `/etc/codex/requirements.toml` (`auth.command`), rendered by workspace-ansible, run `bao kv get -field=api_key kv/xolotl/keys/<xolotl_key>` through `vault.sock`. `xolotl_key` is the Xolotl `<policy>/<client>` of the key (default `devcontainer/<workspace>`), and `kv/xolotl` is the deployed Xolotl's KV v2 mount and prefix, in the `wyrwood` namespace it shares with Wyrwood. The bound Wyrwood policy must allow `read` on `kv/data/xolotl/keys/<xolotl_key>`.

## `vscode` user

The `vscode` user is created by the [base Ubuntu image](https://github.com/wyrd-company/devcontainers/tree/main/src/images/base-ubuntu) used by these devcontainers. This image tracks the [upstream Microsoft devcontainers base](https://github.com/devcontainers/images/tree/main/src/base-ubuntu), but adds [S6-overlay](https://github.com/just-containers/s6-overlay) as the init process.