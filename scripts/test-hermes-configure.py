#!/usr/bin/env python3
"""Offline regression checks for the container configuration script."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("hermes-configure.sh")


class HermesConfigureTest(unittest.TestCase):
    def test_named_provider_defaults_to_gpt_and_pins_only_own_models(self):
        for shell in ("sh", "dash"):
            if not shutil.which(shell):
                continue
            for user in ("teodor", "teodora"):
                with self.subTest(shell=shell, user=user), tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    recorder = root / "hermes"
                    recorder.write_text(
                        "#!/usr/bin/env python3\n"
                        "import json, os, sys\n"
                        "with open(os.environ['CONFIG_CALLS'], 'a') as f:\n"
                        "    f.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                    )
                    recorder.chmod(0o700)
                    calls_file = root / "calls.jsonl"
                    env = dict(
                        os.environ,
                        PATH=f"{root}{os.pathsep}{os.environ['PATH']}",
                        CONFIG_CALLS=str(calls_file),
                        LITELLM_BASE_URL="http://litellm:4000/v1",
                        LITELLM_MODEL=f"chat-{user}",
                        OPENAI_API_KEY="test-key-must-not-be-written",
                    )
                    subprocess.run([shell, str(SCRIPT)], env=env, check=True, capture_output=True)
                    config = {}
                    for line in calls_file.read_text().splitlines():
                        args = json.loads(line)
                        self.assertEqual(args[:2], ["config", "set"])
                        args = [arg for arg in args[2:] if arg != "--force"]
                        key, value = args
                        try:
                            value = json.loads(value)
                        except json.JSONDecodeError:
                            pass
                        config[key] = value
                    self.assertIn("providers.family", config)
                    provider = config["providers.family"]
                    self.assertEqual(provider["base_url"], env["LITELLM_BASE_URL"])
                    self.assertEqual(provider["key_env"], "OPENAI_API_KEY")
                    self.assertIs(provider["discover_models"], False)
                    self.assertEqual(
                        provider["models"],
                        [f"chat-{user}-gpt", f"chat-{user}", f"chat-{user}-pro"],
                    )
                    self.assertEqual(config["model.provider"], "custom")
                    self.assertEqual(config["model.default"], f"chat-{user}-gpt")
                    self.assertEqual(config["model.api_key"], "${OPENAI_API_KEY}")
                    for alias, target in (
                        ("flash", f"chat-{user}"),
                        ("pro", f"chat-{user}-pro"),
                        ("gpt", f"chat-{user}-gpt"),
                    ):
                        self.assertEqual(config[f"model_aliases.{alias}"]["model"], target)
                        self.assertEqual(config[f"model_aliases.{alias}"]["api_key"], "${OPENAI_API_KEY}")
                    self.assertNotIn(env["OPENAI_API_KEY"], calls_file.read_text())


class MacSecretsTest(unittest.TestCase):
    def test_adds_openai_key_without_rotating_existing_secrets(self):
        with tempfile.TemporaryDirectory() as tmp:
            env_file = Path(tmp) / ".env"
            original = "POSTGRES_PASSWORD=existing-password\nDEEPSEEK_API_KEY=existing-deepseek\n"
            env_file.write_text(original)
            env_file.chmod(0o600)
            env = dict(
                os.environ,
                ENV_FILE=str(env_file),
                OPENAI_API_KEY="sk-offline-openai-key",
                ROTATE="0",
            )
            script = SCRIPT.parents[1] / "mac" / "secrets.sh"
            result = subprocess.run(["bash", str(script)], env=env, check=True, capture_output=True, text=True)
            self.assertEqual(env_file.read_text(), original + "\nOPENAI_API_KEY=sk-offline-openai-key\n")
            self.assertEqual(env_file.stat().st_mode & 0o777, 0o600)
            self.assertNotIn(env["OPENAI_API_KEY"], result.stdout + result.stderr)
            before = env_file.read_bytes()
            env["OPENAI_API_KEY"] = "sk-different-key-must-not-replace-existing"
            subprocess.run(["bash", str(script)], env=env, check=True, capture_output=True)
            self.assertEqual(env_file.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
