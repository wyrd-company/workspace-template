# Workspaces

A workspace is a devcontainer dedicated to a product or theme, such as `toolchain`,
together with the local file tree it serves. It is a standardized environment for
agents and the people directing them.

Operators primarily work through agents via T3 Code. If they connect through SSH
or VS Code, they use the same shared `vscode` execution account. A workspace does
not provide a separate operating system account or personal configuration profile
for each human. Git commits and pushes use the explicitly selected human
operator's identity and key.

```tree
├── .devcontainer/                 # /etc/devcontainer (r/o; local/scripts.d writable)
├── config.yml                     # /etc/workspace/config.yml (r/o), the template answers
├── docker/                        # $WORKSPACE_HOME/docker: compose projects, docker-outside-of-docker only
├── repos/                         # /repos: bare clones memory.git, tasks.git, workflows.git
├── state/
│   ├── claude/                    # ~/.claude
│   ├── codex/                     # ~/.codex
│   ├── pi/                        # ~/.pi
│   ├── t3/                        # ~/.t3/userdata
│   └── workflows/                 # ~/.local/share/dagu (Dagu state)
├── tasks/                         # /tasks: worktree of branch workspace/{workspace} of tasks
├── workflows/                     # /workflows
│   ├── local/                     # worktree of branch workspace/{workspace}
│   ├── main/                      # worktree of main
│   └── worktrees/                 # branches for changes: main/ for PRs to main, local/ for workspace/{workspace}
└── workspace/                     # /workspace (workspaceFolder)
    ├── AGENTS.md                  # workspace instructions
    └── {workspace}.code-workspace
```

## Standardization

`workspace-ansible` and `workspace-dotfiles` work together to standardize the
workspace. Their boundary follows configuration ownership: Ansible manages
root-owned configuration, and dotfiles manages configuration owned by `vscode`.
Both provide common workspace configuration.

Prefer configuring common settings in `/etc/**` when supported by the application.
When an application requires settings in the execution account's home directory,
manage those settings through dotfiles. The application's use of a user-level
configuration file does not imply a human operator's personal preferences.

The same framing is included in the generated `workspace/AGENTS.md`, so agents
receive it as workspace-wide context.

## Backups

Menagerie commits and pushes the workspace's Git repository. The `.gitignore` files decide what that holds:

| Path | In a backup |
| --- | --- |
| `.devcontainer/`, `config.yml`, `.toha.json`, `.gitignore` | Yes |
| `state/.gitignore`, `state/*/.gitignore` | Yes, only these six files under `state/` |
| Anything else under `state/` | No |
| `repos/`, `tasks/`, `workflows/` | No. Their contents are Git repositories with their own remotes |
| `docker/` | No |
| Files directly in `workspace/` | Yes. They are workspace files |
| Folders in `workspace/` | No. They are clones |

A backup does not restore agent credentials, history or databases. `repos`, `tasks`, `workflows` and `docker` are not in Git, and they hold no placeholder file, so that `tasks` stays empty for `git worktree add`. A fresh clone of a backup has none of them, and the container cannot start while a bind source is missing. Toha creates them when it applies the template. On a fresh clone, create them with `mkdir` before the first start; once Menagerie creates its own bind sources ([menagerie#54](https://github.com/wyrd-company/menagerie/issues/54)), this step goes away.

## `state`

This stores agent-specific state. Git ignores all of it except each folder's `.gitignore`.

- `claude` is where the local claude profile is stored
- `codex` is where the local codex profile is stored
- `pi` is where the local pi profile is stored
- `t3` is where the t3code server user data is stored
- `workflows` is where Dagu stores its state

The settings each harness must enforce are not here: workspace-ansible renders them into `/etc/claude-code/` and `/etc/codex/`.

### `t3`

This stores the [T3Code](https://t3.codes) server user/state data directory.

The following files are provided as `chezmoi` [dotfiles](https://github.com/wyrd-company/workspace-dotfiles):

```dotfiles
├── keybindings.json # dotfile
└── settings.json # dotfile
```

## `repos`

This holds the bare clones the worktrees are checked out from: `tasks/` and `workflows/` here, and the `memory` and `tasks` worktrees each project template adds. workspace-ansible clones them at every start.

### `memory`

I use [`mnemonic`](https://github.com/danielmarbach/mnemonic) MCP server as a ubiquitous memory system for agents. Each project checks out its own branch of the `memory` repository for its memories. A user-level vault, shared by every workspace on the host, is mounted at `~/mnemonic-vault`.

I depart from the normal usage documented by `mnemonic` and use one memory vault for all repos in a project, git ignoring any .mnemonic folder globally.

Agents store observations and ephemeral handoffs and notes using mnemonic. Anything more permanent is a doc, task, Skill, or in the AGENTS.md.

## `tasks`

This is the worktree of the workspace's branch, `workspace/{workspace}`, of the `tasks` repository.

## `workflows`

Every workspace can run workflows using [Dagu](https://dagu.sh).

Local workflows are stored in a branch of my [`workflows` repository](https://github.com/wyrd-company/workflows). workspace-ansible checks out both branches into their bind-mounted folders at every start, and creates the local branch from the template on `main` if it doesn't exist yet. The local branch has the following structure:

```/workflows/local
├── bin/     # Scripts called by the local dags, on the Dagu PATH
├── dags/    # Local workflows - what actually runs
├── tests/   # Any test scripts for your local workflows
└── wiki/    # Documentation for local workflows
```

Shared sub-dag workflows, scripts, and tests are in the `main` branch/folder:

```/workflows/main
├── bin       # Scripts used by the sub-dags, on the Dagu PATH
├── sub-dags  # Shared sub-dag workflows
├── template  # Toha template for new local branches
└── tests
```

`main` is read only in the container; changes go through PRs from branches in `worktrees`.

## `workspace`

This folder contains the actual devcontainer workspace, bind mounted to `/workspace`.

It could be a single monorepo.
It could be an umbrella folder containing multiple repositories.

## `AGENTS.md`

`workspace/AGENTS.md` is the core context for the workspace provided to the agents. It contains workspace specific information.
