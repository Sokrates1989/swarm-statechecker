"""Verify normal stack deploy pins both images before touching Swarm services.

Docker is stubbed at the Bash boundary; these tests do not contact a daemon.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MENU_HANDLERS = ROOT / "setup" / "modules" / "menu_handlers.sh"
API_DIGEST = "a" * 64
WEB_DIGEST = "b" * 64


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "POSIX Bash required")
class DigestDeployTests(unittest.TestCase):
    """Exercise digest resolution and deploy ordering with disposable inputs."""

    def run_deploy(self, mode: str) -> tuple[subprocess.CompletedProcess[str], list[str], str]:
        """Run one deploy mode and return process, Docker events, and dotenv content."""
        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            environment_file = directory / ".env"
            environment_file.write_text(
                "STACK_NAME=statechecker\n"
                "IMAGE_NAME=sokrates1989/statechecker\n"
                "IMAGE_VERSION=3.0.2\n"
                "WEB_IMAGE_NAME=sokrates1989/statechecker-web\n"
                "WEB_IMAGE_VERSION=3.0.2\n",
                encoding="utf-8",
            )
            events_file = directory / "events.txt"
            process = subprocess.run(
                [
                    "bash", "-c",
                    r'''
                        source "$1"
                        cd "$2"
                        MODE="$3"
                        EVENTS_FILE="$4"
                        API_DIGEST="$5"
                        WEB_DIGEST="$6"
                        load_env() {
                            STACK_NAME=statechecker
                            IMAGE_NAME=sokrates1989/statechecker
                            IMAGE_VERSION=3.0.2
                            WEB_IMAGE_NAME=sokrates1989/statechecker-web
                            WEB_IMAGE_VERSION=3.0.2
                            TELEGRAM_ENABLED=true
                            EMAIL_ENABLED=true
                        }
                        _get_compose_command() { printf '%s\n' 'docker compose'; }
                        run_deployment_preflight() {
                            printf '%s\n' 'preflight' >> "$EVENTS_FILE"
                        }
                        check_secret_exists() { return 0; }
                        preflight_rendered_stack() { return 0; }
                        _render_stack_config() {
                            local api_image="$API_IMAGE_REFERENCE"
                            if [ "$MODE" = render-unpinned ]; then
                                api_image='sokrates1989/statechecker:3.0.2'
                            fi
                            printf 'services:\n  api:\n    image: %s\n  check:\n    image: %s\n  web:\n    image: %s\n' \
                                "$api_image" "$API_IMAGE_REFERENCE" "$WEB_IMAGE_REFERENCE" > "$3"
                            printf 'render api=%s web=%s\n' \
                                "$API_IMAGE_REFERENCE" "$WEB_IMAGE_REFERENCE" >> "$EVENTS_FILE"
                        }
                        docker() {
                            local image
                            case "$1 $2" in
                                'pull '*)
                                    printf 'pull %s\n' "$2" >> "$EVENTS_FILE"
                                    if [ "$MODE" = pull-fails ] && [[ "$2" == *-web:* ]]; then
                                        return 1
                                    fi
                                    ;;
                                'image inspect')
                                    image="${*: -1}"
                                    if [[ "$image" == *-web:* ]]; then
                                        if [ "$MODE" = web-digest-missing ]; then
                                            return 0
                                        fi
                                        if [ "$MODE" = web-digest-ambiguous ]; then
                                            printf '%s\n' \
                                                "sokrates1989/statechecker-web@sha256:$WEB_DIGEST" \
                                                "sokrates1989/statechecker-web@sha256:$API_DIGEST"
                                            return 0
                                        fi
                                        printf '%s\n' "sokrates1989/statechecker-web@sha256:$WEB_DIGEST"
                                    else
                                        printf '%s\n' "sokrates1989/statechecker@sha256:$API_DIGEST"
                                    fi
                                    ;;
                                'stack deploy')
                                    printf 'deploy %s\n' "$5" >> "$EVENTS_FILE"
                                    ;;
                                'stack services')
                                    printf '%s\n' 'statechecker_api 1/1'
                                    ;;
                                *) return 1 ;;
                            esac
                        }
                        deploy_stack
                    ''',
                    "statechecker-deployment-test",
                    str(MENU_HANDLERS), str(directory), mode, str(events_file),
                    API_DIGEST, WEB_DIGEST,
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            events = events_file.read_text(encoding="utf-8").splitlines()
            return process, events, environment_file.read_text(encoding="utf-8")

    def test_deploy_renders_digest_references_and_keeps_version_tags(self) -> None:
        """Pin the normal render without changing the operator's dotenv tags."""
        process, events, environment = self.run_deploy("success")

        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(events[0], "preflight")
        self.assertEqual(events[1:3], [
            "pull sokrates1989/statechecker:3.0.2",
            "pull sokrates1989/statechecker-web:3.0.2",
        ])
        self.assertEqual(
            events[3],
            "render api=sokrates1989/statechecker@sha256:"
            f"{API_DIGEST} web=sokrates1989/statechecker-web@sha256:{WEB_DIGEST}",
        )
        self.assertEqual(events[4], "deploy statechecker")
        self.assertIn("IMAGE_VERSION=3.0.2", environment)
        self.assertIn("WEB_IMAGE_VERSION=3.0.2", environment)

    def test_deploy_stops_before_service_change_when_pull_fails(self) -> None:
        """A missing web image prevents any stack mutation."""
        process, events, _ = self.run_deploy("pull-fails")

        self.assertNotEqual(process.returncode, 0)
        self.assertFalse(any(event.startswith("render ") for event in events))
        self.assertFalse(any(event.startswith("deploy ") for event in events))

    def test_deploy_rejects_missing_or_ambiguous_digests(self) -> None:
        """Never use tag references when the pulled digest is uncertain."""
        for mode in ("web-digest-missing", "web-digest-ambiguous"):
            with self.subTest(mode=mode):
                process, events, _ = self.run_deploy(mode)

                self.assertNotEqual(process.returncode, 0)
                self.assertFalse(any(event.startswith("render ") for event in events))
                self.assertFalse(any(event.startswith("deploy ") for event in events))

    def test_deploy_rejects_render_that_drops_digest_override(self) -> None:
        """A stale generated stack cannot silently redeploy a mutable tag."""
        process, events, _ = self.run_deploy("render-unpinned")

        self.assertNotEqual(process.returncode, 0)
        self.assertIn("does not match its resolved digest", process.stdout)
        self.assertTrue(any(event.startswith("render ") for event in events))
        self.assertFalse(any(event.startswith("deploy ") for event in events))


if __name__ == "__main__":
    unittest.main()
