"""Render the template with toha for a matrix of answers and parse every JSON file it writes.

devcontainer.json and the other JSON files are JSONC, with comments and trailing commas. Jinja conditionals
make it easy to drop a comma, and nothing else notices until a rebuild fails. Needs toha on PATH and nothing
else: python3 -m unittest discover -s tests
"""

import itertools
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SDKS = ["bun", "dart", "dotnet", "flutter", "go", "node", "python", "rust"]
DOCKER = ["none", "docker-in-docker", "docker-outside-of-docker"]


def strip_jsonc(text):
    """Remove comments and trailing commas, leaving strings alone."""
    out, i, n, in_string = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_string:
            out.append(c)
            if c == "\\":
                out.append(text[i + 1])
                i += 1
            elif c == '"':
                in_string = False
        elif c == '"':
            in_string = True
            out.append(c)
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
            continue
        elif text.startswith("/*", i):
            i = text.index("*/", i) + 2
            continue
        else:
            out.append(c)
        i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def no_duplicate_keys(pairs):
    keys = [key for key, _ in pairs]
    duplicates = sorted({key for key in keys if keys.count(key) > 1})
    if duplicates:
        raise ValueError(f"duplicate keys: {duplicates}")
    return dict(pairs)


def parse_jsonc(path):
    return json.loads(strip_jsonc(path.read_text()), object_pairs_hook=no_duplicate_keys)


def answer_sets():
    sdk_sets = [[], SDKS] + [[sdk] for sdk in SDKS]
    for docker, sdks in itertools.product(DOCKER, sdk_sets):
        yield {"sdks": sdks, "docker": docker, "enable_gpu": False}
    yield {"sdks": SDKS, "docker": "docker-in-docker", "enable_gpu": True}


@unittest.skipUnless(shutil.which("toha"), "needs toha")
class RenderedJsonTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="render-test-")
        root = Path(cls.temp.name)
        cls.env = {**os.environ, **{
            f"XDG_{name}_HOME": str(root / "toha" / name.lower()) for name in ("CONFIG", "DATA", "STATE", "CACHE")}}
        (root / "toha/config/toha").mkdir(parents=True)
        cls.root = root

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def render(self, index, answers):
        target = self.root / "targets" / f"w{index}"
        answers_file = self.root / f"answers-{index}.json"
        answers_file.write_text(json.dumps(
            {"template": str(REPO), "answers": {"remote": "", **answers}}))
        result = subprocess.run(["toha", "apply", str(REPO), str(target), "--answers", str(answers_file)],
                                env=self.env, text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return target

    def test_every_rendered_json_file_parses(self):
        for index, answers in enumerate(answer_sets()):
            with self.subTest(**answers):
                target = self.render(index, answers)
                files = [path for path in target.rglob("*")
                         if path.suffix in (".json", ".code-workspace") and path.name != ".toha.json"]
                self.assertIn(target / ".devcontainer/devcontainer.json", files)
                for path in files:
                    try:
                        parse_jsonc(path)
                    except ValueError as error:  # JSONDecodeError is a ValueError
                        self.fail(f"{path.relative_to(target)} for {answers}: {error}")

    def test_container_timezone_follows_the_answer(self):
        for index, answers, expected in (
            ("timezone-default", {}, "America/Los_Angeles"),
            ("timezone-custom", {"timezone": "Europe/Paris"}, "Europe/Paris"),
        ):
            with self.subTest(**answers):
                target = self.render(index, answers)
                devcontainer = parse_jsonc(target / ".devcontainer/devcontainer.json")
                self.assertEqual(devcontainer["containerEnv"]["TZ"], expected)

    def test_features_follow_the_answers(self):
        features = parse_jsonc(self.render("features", {"sdks": ["go"], "docker": "docker-outside-of-docker"})
                               / ".devcontainer/devcontainer.json")["features"]
        self.assertIn("ghcr.io/wyrd-company/devcontainers/go:latest", features)
        self.assertIn("ghcr.io/wyrd-company/devcontainers/docker-outside-of-docker:latest", features)
        self.assertNotIn("ghcr.io/devcontainers/features/rust:1", features)

    def test_rust_mounts_only_cargo_caches_and_keeps_rustup_first_on_path(self):
        target = self.render("rust", {"sdks": ["rust"]})
        devcontainer = parse_jsonc(target / ".devcontainer/devcontainer.json")
        cargo_mounts = [mount for mount in devcontainer["mounts"] if mount["target"].startswith("/usr/local/cargo")]
        self.assertEqual(cargo_mounts, [
            {"source": "/workspaces/.shared/caches/cargo/registry", "target": "/usr/local/cargo/registry",
             "type": "bind"},
            {"source": "/workspaces/.shared/caches/cargo/git", "target": "/usr/local/cargo/git", "type": "bind"},
        ])  # Never CARGO_HOME itself: bin/ holds the rust feature's rustup proxies.
        self.assertEqual(devcontainer["features"]["ghcr.io/devcontainers/features/rust:1"],
                         {"targets": "wasm32-unknown-unknown"})
        local = parse_jsonc(target / ".devcontainer/local/devcontainer-feature.json")
        self.assertEqual(local["containerEnv"]["PATH"], "/usr/local/cargo/bin:${PATH}")

    def test_rust_targets_follow_the_answer(self):
        features = lambda answers: parse_jsonc(
            self.render(f"rust-{len(answers)}", answers) / ".devcontainer/devcontainer.json")["features"]
        self.assertEqual(features({"sdks": ["rust"], "rust_targets": "wasm32-unknown-unknown, wasm32-wasip1"})
                         ["ghcr.io/devcontainers/features/rust:1"],
                         {"targets": "wasm32-unknown-unknown,wasm32-wasip1"})
        self.assertEqual(features({"sdks": ["rust"], "rust_targets": "", "docker": "none"})
                         ["ghcr.io/devcontainers/features/rust:1"], {})

    def test_no_cargo_mounts_or_path_without_rust(self):
        target = self.render("no-rust", {"sdks": ["go"]})
        mounts = parse_jsonc(target / ".devcontainer/devcontainer.json")["mounts"]
        self.assertFalse([mount for mount in mounts if "cargo" in mount["target"]])
        self.assertNotIn("containerEnv", parse_jsonc(target / ".devcontainer/local/devcontainer-feature.json"))

    def test_mnemonic_vault_uses_lowercase_org(self):
        target = self.render("mnemonic", {"org": "Iradesa", "upstream_org": "wyrd-company"})
        mounts = parse_jsonc(target / ".devcontainer/devcontainer.json")["mounts"]
        self.assertEqual([mount for mount in mounts if mount["target"] == "/home/vscode/mnemonic-vault"], [{
            "source": "/workspaces/.shared/mnemonic-vaults/iradesa",
            "target": "/home/vscode/mnemonic-vault",
            "type": "bind",
        }])

    def test_workspace_skills_are_empty_and_mounted_read_write(self):
        target = self.render("skills", {})
        skills = target / "skills"
        self.assertEqual(list(skills.iterdir()), [skills / ".gitkeep"])
        self.assertEqual((skills / ".gitkeep").read_bytes(), b"")
        mounts = parse_jsonc(target / ".devcontainer/devcontainer.json")["mounts"]
        skills_mounts = [mount for mount in mounts if mount["target"].split(",")[0] == "/skills"]
        self.assertEqual(skills_mounts, [{
            "source": "${localWorkspaceFolder}/skills",
            "target": "/skills",
            "type": "bind",
        }])  # A bind mount is read-write by default; no read-only option or target suffix.

    def test_local_feature_lists_every_home_mount(self):
        """The local feature creates the parents of these targets as the user; Docker would create them as root."""
        home = "/home/vscode/"
        mounted = set()
        for index, answers in enumerate(answer_sets()):
            target = self.render(f"home-mounts-{index}", answers)
            mounts = parse_jsonc(target / ".devcontainer/devcontainer.json")["mounts"]
            mounted |= {mount["target"].split(",")[0][len(home):] for mount in mounts
                        if mount["target"].startswith(home)}
            install = (target / ".devcontainer/local/install.sh").read_text()
        listed = re.search(r"^home_mount_targets=\(\n(.*?)\n\)", install, re.S | re.M)
        self.assertIsNotNone(listed, "install.sh has no home_mount_targets array")
        self.assertEqual(sorted(listed.group(1).split()), sorted(mounted))


    def config(self, index, answers):
        text = (self.render(index, answers) / "config.yml").read_text()
        return dict(line.split(": ", 1) if ": " in line else (line.rstrip(":"), "") for line in text.splitlines())

    def test_upstream_org_is_rendered_when_set(self):
        config = self.config("upstream-set", {"org": "boblangley", "upstream_org": "wyrd-company"})
        self.assertEqual(config["org"], "boblangley")
        self.assertEqual(config["upstream_org"], '"wyrd-company"')

    def test_upstream_org_is_empty_by_default(self):
        self.assertEqual(self.config("upstream-empty", {})["upstream_org"], '""')
        self.assertEqual(self.config("upstream-blank", {"upstream_org": ""})["upstream_org"], '""')


class JsoncParserTests(unittest.TestCase):
    """The checks above are only as good as the parser: it must reject what broke 0.3.0."""

    def parse(self, text):
        return json.loads(strip_jsonc(text), object_pairs_hook=no_duplicate_keys)

    def test_accepts_comments_trailing_commas_and_slashes_in_strings(self):
        self.assertEqual(
            self.parse('{\n  // c\n  "a": "unix:///run/x.sock", /* b */\n  "b": [1, 2,],\n}'),
            {"a": "unix:///run/x.sock", "b": [1, 2]})

    def test_rejects_a_missing_comma(self):
        with self.assertRaises(ValueError):
            self.parse('{\n  "a": {\n  }\n  "b": {}\n}')

    def test_rejects_duplicate_keys(self):
        with self.assertRaisesRegex(ValueError, "duplicate keys"):
            self.parse('{"a": 1, "a": 2}')


if __name__ == "__main__":
    unittest.main()
