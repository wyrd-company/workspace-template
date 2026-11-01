---
alwaysApply: true
---
<{{workspace}}-workspace-context>
This devcontainer is the **{{ name }}** workspace. Paths inside the container:

```
/workspace/              # This workspace: product/domain theme projects; you are here
/workflows/local/        # Dagu workflows for this workspace (branch {{ workspace }} of workflows)
/workflows/main/         # Shared Dagu sub-dags and scripts (main of workflows): read only; change via PR from /workflows/worktrees/
/etc/devcontainer/       # This container's definition, read only; propose changes as PRs. local/scripts.d/ is writable.
```
</{{workspace}}-workspace-context>
