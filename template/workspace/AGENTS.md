---
alwaysApply: true
---
<{{workspace}}-workspace-context>
This devcontainer is the **{{ name }}** workspace, dedicated to a product or theme. It is a long lived container.

Operators primarily work through agents in T3 Code. Direct SSH and VS Code access uses the same shared `vscode` execution account. There are no per-human operating system accounts in the workspace; `vscode` and its home directory are part of the standardized workspace environment.

`/skills` is the writable host `skills/` folder for workspace-wide skill overlays;  for what belongs there.

Human operator identity is selected explicitly for Git commits and pushes, using that operator's identity and key. It does not select a different OS account or configuration profile.

Notable paths inside the container: See the `standards` skill's workspace standard for how the workspace environment is configured and how to fit it to this workspace's needs.

```
/etc/devcontainer/                 # This container's definition, read only; propose changes as PRs. 
/etc/devcontainer/local/scripts.d/ # Local workspace-only setup scripts that will be run on rebuild.
/etc/caddy/conf.d/                 # Local Caddy config snippets. Use to setup *.{{domain_name}} reverse proxy sites.
/etc/trowel/conf.d/                # Local Trowel config snippets. Use to setup NATS->webhook/exec handlers.
/etc/vector/conf.d/                # Local Vector config snippets. Use to setup new Vector pipelines.
/etc/workspace/config.yml          # Config values set when the workspace was created.
/skills/                           # Workspace-level skills; see the [instructions standard](https://github.com/wyrd-company/skills/blob/main/standards/references/instructions.md)
/tasks/                            # Workspac-level kanban-md tasks
/workspace/                        # This workspace: product/domain theme projects; you are here
/workflows/local/                  # Dagu workflows for this workspace (branch workspace/{{ workspace }} of workflows)
/workflows/main/                   # Shared Dagu sub-dags and scripts (main of workflows): read only; change via PR from /workflows/worktrees/
```

## Installed:

SDKs:
{{ sdks | toyaml | indent(0) }}

Docker: {{docker}}

## Projects
<!-- >>> toha:workspace projects >>> -->
<!-- <<< toha:workspace projects <<< -->

## Workspace Instructions
<!-- >>> toha:workspace custom instructions >>> -->
<!-- <<< toha:workspace custom instructions <<< -->
</{{workspace}}-workspace-context>
