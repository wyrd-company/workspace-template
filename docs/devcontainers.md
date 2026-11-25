# Devcontainers

All devcontainers in the workspace use Wyrd Company's [Ubuntu base image](https://github.com/wyrd-company/devcontainers/tree/main/src/images/base-ubuntu). This image tracks the [upstream Microsoft devcontainers base](https://github.com/devcontainers/images/tree/main/src/base-ubuntu), but adds [S6-overlay](https://github.com/just-containers/s6-overlay) as the init process.

## Configuration

## Layout

```
/etc/devcontainer/                 # r/o mount of the workspace .devcontainer folder
│   └── local/scripts.d/           # the one writable part: scripts the local feature runs at image build
/etc/workspace/config.yml          # r/o mount of the workspace config.yml (the template answers)
/etc/claude-code/ /etc/codex/ /etc/grok/   # harness system settings, rendered by workspace-ansible
/etc/dagu/ /etc/trowel/ /etc/opentelemetry-collector/   # service configs, rendered by workspace-ansible
/home/vscode/                      # `vscode` profile: .claude, .codex, .gemini, .pi, .t3/userdata are workspace mounts (state/)
│   ├── .agents/skills/            # built real-directory skills view read by Pi and Codex
│   ├── .claude/skills/            # per-skill links into ~/.agents/skills for Claude Code
│   ├── .local/share/skills/base/  # clean main clone of wyrd-company/skills; skill PRs use worktrees of it
│   ├── .local/share/charm/        # Skate store (resource ledgers), a workspace mount (state/charm)
│   ├── .local/share/dagu/         # Dagu state, a workspace mount (state/workflows)
│   ├── .local/state/git-operators/ # each T3 thread's Git operator, a workspace mount (state/git-operators)
│   └── mnemonic-vault/            # user-level vault shared by workspaces with the same GitHub account
/repos/                            # bare clones: memory.git, tasks.git, workflows.git
/skills/                           # r/w mount of the workspace skills/ folder: workspace-wide skill overlays
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

## Local feature

The workspace-local feature, `.devcontainer/local/install.sh`, runs as root at image build, after the other features. It:

- installs the system packages the workspace's tools need;
- creates each missing folder above a bind mount target in the `vscode` home, owned by `vscode`. Docker creates a missing parent of a mount target as root when it starts the container, which leaves `vscode` unable to write beside the mount: `agent-browser`, for one, cannot take its session lock in `~/.agent-browser`. The script's `home_mount_targets` lists every mount target under the home, and `tests/test_render.py` fails when it differs from the rendered `mounts`, so add a new home mount to both;
- runs each executable in `scripts.d/`, in order.

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

## Rust

The `rust` SDK installs a rustup toolchain with the [devcontainers rust feature](https://github.com/devcontainers/features/tree/main/src/rust). Its `CARGO_HOME` is `/usr/local/cargo`, and `bin/` there holds rustup, cargo, rustc, clippy and rustfmt. The `rust_targets` answer, asked only with the `rust` SDK, lists targets rustup adds beside the host target (comma separated, `wasm32-unknown-unknown` by default). Homebrew can install its own `rust` formula as a build dependency of a formula with no bottle, and the Homebrew feature puts its `bin/` first on `PATH`. The local feature therefore puts `/usr/local/cargo/bin` back in front, so `cargo` and `rustc` are rustup's. Install Rust CLIs with Homebrew, not `cargo install`: `CARGO_HOME/bin` is part of the image and is replaced at each rebuild.

## Skills

The dotfiles keep a clean `main` clone of [`wyrd-company/skills`](https://github.com/wyrd-company/skills) at `~/.local/share/skills/base`. Make skill changes in worktrees of that clone and submit them as PRs. `skills sync` builds the base with overlays and publishes real files at `~/.agents/skills`, which Pi and Codex read. Each `~/.claude/skills/<name>` link points into that published view for Claude Code. See the dotfiles’ [Skills guide](https://github.com/wyrd-company/workspace-dotfiles/blob/main/docs/skills.md) for the layout, migration, updates and rollback.

Workspace-wide skill overlays live in the host's `skills/` folder, mounted read-write at `/skills`; see the [instructions standard](https://github.com/wyrd-company/skills/blob/main/standards/references/instructions.md) for what belongs there.

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
4. Bind `devcontainer-<workspace>` to its policies in the Wyrwood UI, with the declared access group and the policies and values appropriate for the workspace. The sockets appear in the directory.
5. Issue the Xolotl key. Set `MENAGERIE_XOLOTL_KEY` to its `<key policy>/<key name>` address in the devcontainer definition before creating the container in step 2.
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

## Vector

[Vector](https://vector.dev/) watches pipeline files in the workspace's `config/vector/` directory. The version 2 devcontainer feature reads OpenBao secrets through the Wyrwood socket using the base image's `bao-secret` helper.

For an existing workspace, make the pipeline edits and rebuild together.

1. On the host that builds the workspace, run `docker pull ghcr.io/wyrd-company/devcontainers/base:resolute` to refresh the base image that provides `bao-secret`.
2. Replace each `SECRET[environment.NAME]` reference with `SECRET[openbao.<mount>/<path>/<field>]` for the same value and verify that the workspace's Wyrwood policy grants access to that secret. If Vector 1 is still running, it reports `reload aborted` and keeps the current pipelines. Rebuild with Vector 2 immediately after the edits. Restarting the old container with the new references would prevent its pipelines from loading.
3. If an OpenBao Agent template writes `/run/openbao/secrets/vector.env`, remove the template and delete the file after the rebuild.
4. If the workspace has pipelines, run `vector-service validate` inside it to check them and resolve their secret references.

See the [Vector feature upgrade guide](https://github.com/wyrd-company/devcontainers/tree/main/src/features/vector#upgrading-from-version-1).

## Xolotl

Claude Code (Anthropic models), Codex CLI (every other model) and Grok CLI (grok-4.7) talk to the [Xolotl](https://wyrd.foo/docs/xolotl/) gateway (`xolotl_url`). None holds an API key: the settings rendered by workspace-ansible read the key through `vault.sock`. Menagerie sets `MENAGERIE_XOLOTL_KEY` to its `<key policy>/<key name>` address in the container; the workspace configuration passes that address to workspace-ansible. Clients without dynamic MCP header helpers (such as Antigravity) reach Xolotl's MCP gateway through a loopback-only Caddy proxy (`http://127.0.0.1:18317/mcp`) backed by `caddy-header-auth`, which runs `/usr/local/bin/xolotl-mcp-headers` per request.

`kv/xolotl` is the deployed Xolotl's KV v2 mount and prefix, in the `wyrwood` namespace it shares with Wyrwood.

## Provisioning

The rendered `.devcontainer/devcontainer.json` declares the workspace access group, under `customizations.menagerie`, in the form [Menagerie's provisioning declaration](https://github.com/wyrd-company/menagerie/blob/main/docs/specifications/provisioning-declaration.yml) defines. For a workspace called `sample`:

```jsonc
"runArgs": ["--name", "devcontainer-sample"],
"customizations": { "menagerie": {
  "wyrwood": { "accessGroup": 1000 }
}}
```

Menagerie reads the container name from `runArgs`, selects policies, issues the key, makes the binding and creates the container before its first start. An imported workspace keeps its stored policies, values and key through an upgrade.

### Workspace names

A workspace name holds lowercase letters, digits, `_` and `-`, starts with a letter or digit, and has at most 63 characters, so that it can name a Xolotl key and be a Wyrwood policy value. Any other name stops the interview before a file is written, with a template error on `validated_workspace` that quotes the rule. Toha has no way to raise a message of a template's own, so the error ends in `invalid float literal`. No answer or configured default can replace the name.

### No start check

The template has no `postStartCommand` and checks nothing at container start. The container cannot be tested until the dotfiles are applied: tools such as `bao` come from workspace-dotfiles, during the startup playbook, so a check at start would race them and fail the Menagerie job that started the container.

## Host prerequisites

A workspace starts only on a host that has these. Menagerie reports the missing folders and networks in one message before it does anything else; it creates nothing outside the workspace folder.

### Shared folders

Folders under `/workspaces/.shared`, owned by the `vscode` user (UID 1000):

| Folder | Holds |
| --- | --- |
| `ca-certificates` | The host's root certificates, with `homelab-root.crt` |
| `caches/homebrew`, `caches/npm/global`, `caches/npm/local`, `caches/pnpm`, `caches/uv/packages`, `caches/uv/tools`, `caches/gh/extensions`, `caches/browsers` | Caches for every workspace |
| `caches/go-pkg` | Go cache, for a workspace with the `go` SDK |
| `caches/cargo/registry`, `caches/cargo/git` | Cargo's download caches, for a workspace with the `rust` SDK. They are mounted on those folders of `CARGO_HOME` (`/usr/local/cargo`) only, so the rust feature's `bin/` stays in the image |
| `mnemonic-vaults/<org>` | Checkout of `main` from the GitHub account's private `memory` repository |

Before creating or updating a workspace, provision its vault at
`/workspaces/.shared/mnemonic-vaults/<org>`. Use the lowercase value of the
workspace template's `org` answer for `<org>`. The container mounts this checkout at
`/home/vscode/mnemonic-vault`.

### `homelab` network

A Docker network called `homelab` that containers can attach to, shared with the main server's Caddy.

### Wyrwood policies and Xolotl key policy

Configure Menagerie with the workspace policies and the Xolotl key policy for the host. The selected Wyrwood policies must allow the workspace to use its sockets and read its issued key. Menagerie stores each workspace's selection and key address.

## `vscode` user

The `vscode` user is created by the [base Ubuntu image](https://github.com/wyrd-company/devcontainers/tree/main/src/images/base-ubuntu) used by these devcontainers. This image tracks the [upstream Microsoft devcontainers base](https://github.com/devcontainers/images/tree/main/src/base-ubuntu), but adds [S6-overlay](https://github.com/just-containers/s6-overlay) as the init process.
