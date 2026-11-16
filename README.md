# workspace-template
A toha template for Wyrd workspaces

The interview asks for an optional workspace remote URL. Toha initializes the
generated workspace as a Git repository even when the URL is empty, so it can
save `.toha.json` for template tracking and updates. An existing repository is
left unchanged.

- [Workspaces](docs/workspaces.md): the file tree and what a backup holds.
- [Devcontainers](docs/devcontainers.md): the container, provisioning and host prerequisites.

## Tests

`python3 -m unittest discover -s tests` renders the template with `toha` for every Docker option, with no SDKs, each SDK alone and all of them, and parses each JSON file it writes as JSONC (comments and trailing commas allowed, duplicate keys rejected). A dropped comma between Jinja conditionals otherwise shows up only when a devcontainer fails to rebuild. It needs only `toha` and `python3`, and takes about a second: run it before every commit to `template/` and before tagging.

`tests/provisioning.sh` renders the template and runs `check-provisioning.sh` against a fake `vault.sock` and a real `ssh-agent`. It needs `toha`, `dcb`, a Docker daemon, `bao`, `jq`, `python3` with `jsonschema`, and OpenSSH on `PATH`, and `MENAGERIE_SCHEMA` set to Menagerie's `menagerie-customization.schema.json`. Run it in a sandbox.
