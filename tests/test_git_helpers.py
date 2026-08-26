"""Verify safe repository status checks and self-update menu integration."""

from __future__ import annotations

import os
import shutil
import subprocess
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
GIT_HELPERS = REPOSITORY_ROOT / "setup" / "modules" / "git_helpers.sh"
MENU_HANDLERS = REPOSITORY_ROOT / "setup" / "modules" / "menu_handlers.sh"
EXPECTED_REPOSITORY = f"sokrates1989/{REPOSITORY_ROOT.name}"


def run_bash(
    script: str,
    *arguments: Path | str,
) -> subprocess.CompletedProcess[str]:
    """Run a Bash fragment and capture its output."""

    return subprocess.run(
        ["bash", "-c", script, "git-helpers-test", *map(str, arguments)],
        check=True,
        capture_output=True,
        text=True,
    )


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "POSIX Bash required")
class GitHelperTests(unittest.TestCase):
    """Exercise repository classification without contacting a remote."""

    HARNESS = r'''
        GIT_STUB_REPOSITORY="$2"
        GIT_STUB_MODE="$3"

        git() {
            if [ "$1" = "-C" ]; then
                shift 2
            fi

            case "$1" in
                rev-parse)
                    case "$2" in
                        --is-inside-work-tree)
                            [ "$GIT_STUB_MODE" != "not-git" ] || return 1
                            printf '%s\n' true
                            ;;
                        --abbrev-ref)
                            [ "$GIT_STUB_MODE" != "missing-upstream" ] || return 1
                            printf '%s\n' origin/main
                            ;;
                        HEAD)
                            printf '%s\n' local-head
                            ;;
                        origin/main)
                            case "$GIT_STUB_MODE" in
                                up-to-date|dirty) printf '%s\n' local-head ;;
                                *) printf '%s\n' remote-head ;;
                            esac
                            ;;
                    esac
                    ;;
                remote)
                    if [ "$GIT_STUB_MODE" = "unexpected-origin" ]; then
                        printf '%s\n' https://github.com/example/other.git
                    else
                        printf 'https://github.com/%s.git\n' "$GIT_STUB_REPOSITORY"
                    fi
                    ;;
                symbolic-ref)
                    [ "$GIT_STUB_MODE" != "detached" ] || return 1
                    if [ "$GIT_STUB_MODE" = "unexpected-branch" ]; then
                        printf '%s\n' feature
                    else
                        printf '%s\n' main
                    fi
                    ;;
                status)
                    [ "$GIT_STUB_MODE" != "dirty" ] || printf '%s\n' ' M README.md'
                    ;;
                fetch)
                    [ "$GIT_STUB_MODE" != "remote-unavailable" ]
                    ;;
                merge-base)
                    case "$GIT_STUB_MODE" in
                        behind) printf '%s\n' local-head ;;
                        ahead) printf '%s\n' remote-head ;;
                        *) printf '%s\n' unrelated-head ;;
                    esac
                    ;;
                rev-list)
                    printf '%s\n' 3
                    ;;
                pull)
                    PULL_CALLED=1
                    ;;
            esac
        }

        GIT_EXPECTED_REPOSITORIES="$GIT_STUB_REPOSITORY"
        GIT_EXPECTED_BRANCH=main
        GIT_FETCH_TIMEOUT_SECONDS=0
        GIT_UPDATE_CHECK_TTL_SECONDS=0
        source "$1"
        check_git_updates force
        printf 'status=%s\n' "$_GIT_UPDATE_STATUS"
        printf 'base=%s\n' "$_GIT_UPDATE_BASE_STATUS"
        printf 'behind=%s\n' "$_GIT_UPDATE_BEHIND_COUNT"
        printf 'ahead=%s\n' "$_GIT_UPDATE_AHEAD_COUNT"
        show_git_status_line
    '''

    def test_repository_states_are_classified_explicitly(self) -> None:
        """Distinguish safe updates from every common unsafe checkout state."""

        cases = (
            ("up-to-date", "up-to-date"),
            ("behind", "behind"),
            ("ahead", "ahead"),
            ("diverged", "diverged"),
            ("dirty", "dirty"),
            ("remote-unavailable", "remote-unavailable"),
            ("unexpected-origin", "unexpected-origin"),
            ("unexpected-branch", "unexpected-branch"),
            ("missing-upstream", "unexpected-upstream"),
            ("detached", "detached"),
            ("not-git", "not-git"),
        )

        for mode, expected_status in cases:
            with self.subTest(mode=mode):
                process = run_bash(
                    self.HARNESS,
                    GIT_HELPERS,
                    EXPECTED_REPOSITORY,
                    mode,
                )
                self.assertIn(f"status={expected_status}", process.stdout)

        behind = run_bash(
            self.HARNESS,
            GIT_HELPERS,
            EXPECTED_REPOSITORY,
            "behind",
        )
        self.assertIn("behind=3", behind.stdout)
        self.assertIn("[WARN] 3 update(s) available", behind.stdout)

    def test_dirty_checkout_never_reaches_git_pull(self) -> None:
        """Block mutation even when the operator explicitly selects update."""

        process = run_bash(
            self.HARNESS
            + r'''
                PULL_CALLED=0
                handler_status=0
                handle_git_pull || handler_status=$?
                printf 'handler=%s\n' "$handler_status"
                printf 'pull=%s\n' "$PULL_CALLED"
            ''',
            GIT_HELPERS,
            EXPECTED_REPOSITORY,
            "dirty",
        )

        self.assertIn("handler=1", process.stdout)
        self.assertIn("pull=0", process.stdout)
        self.assertIn("Update blocked", process.stdout)

    def test_clean_behind_checkout_uses_fast_forward_update(self) -> None:
        """Allow the explicit update action only for a clean behind checkout."""

        process = run_bash(
            self.HARNESS
            + r'''
                PULL_CALLED=0
                GIT_RESTART_AFTER_UPDATE=false
                handler_status=0
                handle_git_pull || handler_status=$?
                printf 'handler=%s\n' "$handler_status"
                printf 'pull=%s\n' "$PULL_CALLED"
                printf 'final=%s\n' "$_GIT_UPDATE_STATUS"
            ''',
            GIT_HELPERS,
            EXPECTED_REPOSITORY,
            "behind",
        )

        self.assertIn("handler=0", process.stdout)
        self.assertIn("pull=1", process.stdout)
        self.assertIn("final=up-to-date", process.stdout)
        self.assertIn("Repository updated", process.stdout)

    def test_menu_and_pull_contract_are_discoverable(self) -> None:
        """Keep status, refresh, and update actions wired to the main menu."""

        menu = MENU_HANDLERS.read_text(encoding="utf-8")
        helper = GIT_HELPERS.read_text(encoding="utf-8")

        for fragment in (
            'source "${MENU_HANDLERS_DIR}/git_helpers.sh"',
            "show_git_status_line",
            "check_git_updates",
            "Repository:",
            "r) Refresh repository update state",
            "u) Check for and apply repository update",
            "r|R)",
            "u|U)",
        ):
            self.assertIn(fragment, menu)

        self.assertIn("pull --ff-only --quiet", helper)
        self.assertIn("GIT_TERMINAL_PROMPT=0", helper)
        self.assertIn("unexpected-origin", helper)
        self.assertIn("dirty", helper)


if __name__ == "__main__":
    unittest.main()
