---
alwaysApply: true
---
<{{workspace}}-workspace-context>
This devcontainer is the **{{ name }}** workspace, dedicated to a product or theme.

Operators primarily work through agents in T3 Code. Direct SSH and VS Code access
uses the same shared `vscode` execution account. There are no per-human operating
system accounts in the workspace; `vscode` and its home directory are part of the
standardized workspace environment.

`workspace-ansible` and `workspace-dotfiles` cooperate to standardize that environment.
Root-owned configuration belongs to Ansible; configuration owned by `vscode` belongs
to dotfiles. Prefer common settings in `/etc/**` when the application supports it;
otherwise configure them through dotfiles. A setting's being in the execution
account's home directory does not make it a human operator's personal preference.

Human operator identity is selected explicitly for Git commits and pushes, using
that operator's identity and key. It does not select a different OS account or
configuration profile.

Paths inside the container:

```
/workspace/              # This workspace: product/domain theme projects; you are here
/workflows/local/        # Dagu workflows for this workspace (branch workspace/{{ workspace }} of workflows)
/workflows/main/         # Shared Dagu sub-dags and scripts (main of workflows): read only; change via PR from /workflows/worktrees/
/etc/devcontainer/       # This container's definition, read only; propose changes as PRs. local/scripts.d/ is writable.
```
</{{workspace}}-workspace-context>
