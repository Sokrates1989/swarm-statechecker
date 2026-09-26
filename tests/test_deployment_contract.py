"""Verify reproducible Statechecker setup and deployment contracts.

The tests are local and read-only with respect to Docker. POSIX-only cases
generate stack files inside temporary directories and never contact a daemon.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
SETUP_DIRECTORY = REPOSITORY_ROOT / "setup"
COMPOSE_DIRECTORY = SETUP_DIRECTORY / "compose-modules"
CONFIG_BUILDER = SETUP_DIRECTORY / "modules" / "config-builder.sh"
DEPLOYMENT_PREFLIGHT = (
    SETUP_DIRECTORY / "modules" / "deployment-preflight.sh"
)
DOCKER_HELPERS = SETUP_DIRECTORY / "modules" / "docker_helpers.sh"
HEALTH_CHECK = SETUP_DIRECTORY / "modules" / "health-check.sh"
MENU_FORMATTING = SETUP_DIRECTORY / "modules" / "menu_formatting.sh"
MENU_HANDLERS = SETUP_DIRECTORY / "modules" / "menu_handlers.sh"


def run_bash(
    script: str, *arguments: Path | str, check: bool = True
) -> subprocess.CompletedProcess[str]:
    """Run a Bash fragment with supplied positional arguments.

    Args:
        script: Bash source passed to ``bash -c``.
        *arguments: Values exposed to the fragment as ``$1`` onward.
        check: Whether a nonzero process status raises an exception.

    Returns:
        Completed process with captured standard output and error.
    """

    return subprocess.run(
        ["bash", "-c", script, "statechecker-deployment-test", *map(str, arguments)],
        check=check,
        capture_output=True,
        text=True,
    )


class DeploymentContractTests(unittest.TestCase):
    """Protect version, configuration, wrapper, and validation contracts."""

    def test_environment_templates_pin_the_current_application_version(self) -> None:
        """Keep every supported starting template away from mutable tags."""

        templates = (
            REPOSITORY_ROOT / ".env.template",
            SETUP_DIRECTORY / ".env.template",
            SETUP_DIRECTORY / "env-templates" / ".env.base.template",
        )
        for template in templates:
            content = template.read_text(encoding="utf-8")
            self.assertIn("IMAGE_VERSION=3.0.1", content, template)
            self.assertIn("WEB_IMAGE_VERSION=3.0.1", content, template)
            self.assertNotIn("IMAGE_VERSION=latest", content, template)
            self.assertNotIn("WEB_IMAGE_VERSION=latest", content, template)

    def test_environment_templates_use_five_minute_website_checks(self) -> None:
        """Keep peer monitoring responsive without using a two-minute interval."""

        templates = (
            REPOSITORY_ROOT / ".env.template",
            SETUP_DIRECTORY / ".env.template",
            SETUP_DIRECTORY / "env-templates" / ".env.base.template",
        )
        for template in templates:
            content = template.read_text(encoding="utf-8")
            self.assertRegex(
                content,
                r'(?m)^CHECK_WEBSITES_EVERY_X_MINUTES="?5"?$',
                template,
            )

    def test_guided_websites_use_the_database_seed_contract(self) -> None:
        """Write wizard selections to variables consumed during startup."""

        wizard = (SETUP_DIRECTORY / "setup-wizard.sh").read_text(encoding="utf-8")
        base_environment = (
            SETUP_DIRECTORY / "env-templates" / ".env.base.template"
        ).read_text(encoding="utf-8")

        self.assertIn(
            'update_env_values "$env_file" "INIT_WEBSITES" "$websites_csv"',
            wizard,
        )
        self.assertIn("INIT_WEBSITES=", base_environment)
        self.assertIn("INIT_GOOGLE_DRIVE_FOLDERS=", base_environment)
        self.assertIn("KEYCLOAK_URL=", base_environment)
        self.assertIn('_prompt_keycloak_config "$env_file"', wizard)
        self.assertNotIn("_update_statechecker_server_config", wizard)
        self.assertNotIn("STATECHECKER_SERVER_CONFIG=", base_environment)

    def test_api_and_checker_receive_initial_seed_values(self) -> None:
        """Expose the same initial configuration to both application services."""

        application_templates = "\n".join(
            (COMPOSE_DIRECTORY / file_name).read_text(encoding="utf-8")
            for file_name in ("api.template.yml", "check.template.yml")
        )

        self.assertEqual(application_templates.count("INIT_WEBSITES="), 2)
        self.assertEqual(
            application_templates.count("INIT_GOOGLE_DRIVE_FOLDERS="), 2
        )

    def test_direct_port_placeholders_are_service_level_fields(self) -> None:
        """Keep direct ports outside the Swarm-only deploy section."""

        for file_name, placeholder in (
            ("api.template.yml", "###PROXY_PORTS###"),
            ("web.template.yml", "###PROXY_PORTS_WEB###"),
        ):
            template = (COMPOSE_DIRECTORY / file_name).read_text(encoding="utf-8")
            self.assertLess(template.index(placeholder), template.index("    deploy:"))

    def test_traefik_labels_select_the_swarm_network(self) -> None:
        """Use the Traefik Swarm-provider network override on every router."""

        snippets = COMPOSE_DIRECTORY / "snippets"
        labels = "\n".join(
            path.read_text(encoding="utf-8")
            for path in snippets.glob("proxy-traefik-*.labels.yml")
        )

        self.assertEqual(labels.count("traefik.swarm.network=${TRAEFIK_NETWORK}"), 6)
        self.assertNotIn("traefik.docker.network", labels)

    def test_linux_cli_has_no_powershell_entrypoint_sibling(self) -> None:
        """Keep shell tab completion unambiguous on deployment hosts."""

        powershell_files = sorted(
            path.relative_to(REPOSITORY_ROOT)
            for path in REPOSITORY_ROOT.rglob("*.ps1")
        )

        self.assertEqual(powershell_files, [])
        self.assertTrue((REPOSITORY_ROOT / "quick-start.sh").is_file())

    def test_deploy_path_is_preflighted_and_always_rendered(self) -> None:
        """Validate inputs before secret creation and reject raw stack deploys."""

        menu = (SETUP_DIRECTORY / "modules" / "menu_handlers.sh").read_text(
            encoding="utf-8"
        )
        deploy = menu.split("deploy_stack() {", 1)[1].split(
            "# Helper: Wait for stack", 1
        )[0]

        self.assertLess(
            deploy.index("run_deployment_preflight"),
            deploy.index("docker secret create"),
        )
        self.assertLess(
            deploy.index("preflight_rendered_stack"),
            deploy.index("docker stack deploy"),
        )
        self.assertNotIn("Deploying raw stack file", deploy)

        preflight = DEPLOYMENT_PREFLIGHT.read_text(encoding="utf-8")
        self.assertIn("check_required_secrets", preflight)
        self.assertIn('docker network inspect "$traefik_network"', preflight)
        self.assertIn("preflight_rendered_stack", preflight)

        quick_start = (REPOSITORY_ROOT / "quick-start.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn('tests/render-stack-smoke.sh', quick_start)

    def test_health_contract_checks_convergence_tasks_and_http(self) -> None:
        """Require the operator health command to fail on material problems."""

        health = (SETUP_DIRECTORY / "modules" / "health-check.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("_check_service_convergence", health)
        self.assertIn("_check_active_task_failures", health)
        self.assertIn("curl --fail", health)
        self.assertIn('if [ "$HEALTH_FAILURES" -ne 0 ]', health)
        self.assertIn("return 1", health)

    def test_deploy_waits_for_readiness_before_one_final_health_check(self) -> None:
        """Poll startup convergence instead of issuing an early verdict."""

        menu = (SETUP_DIRECTORY / "modules" / "menu_handlers.sh").read_text(
            encoding="utf-8"
        )
        deploy = menu.split("deploy_stack() {", 1)[1].split(
            "# Helper: Wait for stack", 1
        )[0]

        self.assertIn("POST_DEPLOY_HEALTH_MAX_ATTEMPTS:-10", deploy)
        self.assertIn("POST_DEPLOY_HEALTH_RETRY_SECONDS:-10", deploy)
        self.assertIn("wait_for_deployment_readiness", deploy)
        self.assertIn(
            '"$stack_name" "${PROXY_TYPE:-traefik}" 0 "30m" "200"',
            deploy,
        )
        self.assertNotIn("Waiting 20s", deploy)


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "POSIX Bash required")
class GeneratedStackTests(unittest.TestCase):
    """Exercise stack generation and static preflight in isolation."""

    def test_deployment_overview_uses_converged_service_state(self) -> None:
        """Never label a named but incomplete Swarm stack as running."""

        harness = r'''
            source "$1"
            source "$2"
            STACK_MODE="$3"
            docker() {
                if [ "$1 $2" = "stack ls" ]; then
                    [ "$STACK_MODE" != "unavailable" ] || return 1
                    if [ "$STACK_MODE" = "not-deployed" ]; then
                        printf '%s\n' 'another-stack'
                    else
                        printf '%s\n' 'statechecker'
                    fi
                    return 0
                fi
                if [ "$1 $2" = "stack services" ]; then
                    printf '%s\n' \
                        "statechecker_api|${API_REPLICAS:-1/1}" \
                        'statechecker_check|1/1' \
                        'statechecker_db|1/1' \
                        'statechecker_db-migration|0/1' \
                        'statechecker_web|1/1'
                    return 0
                fi
                if [ "$1 $2" = "service ps" ]; then
                    if [ "$STACK_MODE" = "failed-migration" ]; then
                        printf '%s\n' 'Failed 1 second ago'
                    else
                        printf '%s\n' 'Complete 1 second ago'
                    fi
                    return 0
                fi
                return 1
            }
            if [ "$STACK_MODE" = "incomplete" ]; then
                API_REPLICAS='0/1'
            elif [ "$STACK_MODE" = "scaled-to-zero" ]; then
                API_REPLICAS='0/0'
            fi
            show_deployment_overview /nonexistent/statechecker.env
        '''

        cases = (
            ("converged", "[OK] running"),
            ("incomplete", "[ERROR] not ready"),
            ("scaled-to-zero", "[ERROR] not ready"),
            ("failed-migration", "[ERROR] not ready"),
            ("not-deployed", "[OFF] not deployed"),
            ("unavailable", "[ERROR] unavailable"),
        )
        for stack_mode, expected_status in cases:
            with self.subTest(stack_mode=stack_mode):
                process = run_bash(
                    harness,
                    DOCKER_HELPERS,
                    MENU_HANDLERS,
                    stack_mode,
                )
                self.assertIn(
                    f"Stack    : statechecker ({expected_status})",
                    process.stdout,
                )

    def test_menu_colors_match_the_shared_swarm_palette(self) -> None:
        """Color explicit status labels without corrupting box width."""

        process = run_bash(
            r'''
                source "$1"
                _MENU_COLOR_ENABLED=true
                printf 'ok=%s\n' "$(_menu_colorize ok '[OK] running')"
                printf 'warning=%s\n' "$(_menu_colorize warning '[WARN] review')"
                printf 'error=%s\n' "$(_menu_colorize error '[ERROR] not ready')"
                colorized="$(_menu_colorize error '[ERROR] not ready')"
                printf 'width=%s\n' "$(_calc_display_width "$colorized")"
            ''',
            MENU_FORMATTING,
        )

        self.assertIn("ok=\x1b[32m[OK] running\x1b[0m", process.stdout)
        self.assertIn("warning=\x1b[33m[WARN] review\x1b[0m", process.stdout)
        self.assertIn("error=\x1b[31m[ERROR] not ready\x1b[0m", process.stdout)
        self.assertIn("width=17", process.stdout)

    def test_no_proxy_stack_contains_required_contracts(self) -> None:
        """Generate a complete stack without leaving template placeholders."""

        with tempfile.TemporaryDirectory() as temporary_directory:
            project_root = Path(temporary_directory) / "project"
            modules = project_root / "setup" / "compose-modules"
            shutil.copytree(COMPOSE_DIRECTORY, modules)

            run_bash(
                'source "$1"; build_stack_file none "$2" direct true true',
                CONFIG_BUILDER,
                project_root,
            )
            generated_stack = project_root / "swarm-stack.yml"
            stack = generated_stack.read_text(encoding="utf-8")

            for service in (
                "api",
                "check",
                "db",
                "db-migration",
                "phpmyadmin",
                "web",
            ):
                self.assertIn(f"  {service}:", stack)
            self.assertIn("INIT_WEBSITES=${INIT_WEBSITES:-}", stack)
            self.assertIn("STATECHECKER_SERVER_KEYCLOAK_CLIENT_SECRET", stack)
            self.assertIn('      - "${API_PORT}:${API_PORT}"', stack)
            self.assertIn('      - "${WEB_PORT}:80"', stack)
            self.assertIn('      - "${PHPMYADMIN_PORT}:80"', stack)
            self.assertNotIn("###", stack)

            run_bash(
                'source "$1"; DEPLOYMENT_PREFLIGHT_FAILURES=0; '
                'preflight_stack_contract "$2"',
                DEPLOYMENT_PREFLIGHT,
                generated_stack,
            )

    def test_environment_preflight_rejects_latest(self) -> None:
        """Fail before deployment when a mutable image tag is configured."""

        with tempfile.TemporaryDirectory() as temporary_directory:
            environment_file = Path(temporary_directory) / ".env"
            environment_file.write_text(
                "STACK_NAME=statechecker\n"
                "DATA_ROOT=/tmp/statechecker\n"
                "PROXY_TYPE=none\n"
                "IMAGE_NAME=sokrates1989/statechecker\n"
                "IMAGE_VERSION=latest\n"
                "WEB_IMAGE_NAME=sokrates1989/statechecker-web\n"
                "WEB_IMAGE_VERSION=3.0.1\n"
                "API_PORT=8787\n"
                "WEB_PORT=8080\n",
                encoding="utf-8",
            )

            process = run_bash(
                'source "$1"; DEPLOYMENT_PREFLIGHT_FAILURES=0; '
                'preflight_environment_contract "$2"',
                DEPLOYMENT_PREFLIGHT,
                environment_file,
                check=False,
            )

            self.assertNotEqual(process.returncode, 0)
            self.assertIn("Mutable 'latest' image tags", process.stderr)

    def test_health_status_tracks_external_reachability(self) -> None:
        """Return nonzero when endpoints fail and zero when they are reachable."""

        harness = r'''
            source "$1"
            CURL_MODE="$2"
            docker() {
                if [ "$1 $2" = "stack services" ]; then
                    if [[ "$*" == *"--format"* ]]; then
                        printf '%s\n' \
                            'statechecker_api|1/1' \
                            'statechecker_check|1/1' \
                            'statechecker_db|1/1' \
                            'statechecker_db-migration|0/1' \
                            'statechecker_web|1/1'
                    else
                        printf '%s\n' 'statechecker services'
                    fi
                    return 0
                fi
                if [ "$1 $2" = "stack ps" ]; then
                    return 0
                fi
                if [ "$1 $2" = "service inspect" ]; then
                    return 0
                fi
                if [ "$1 $2" = "service ps" ]; then
                    printf '%s\n' 'Complete 1 second ago'
                    return 0
                fi
                return 0
            }
            curl() {
                [ "$CURL_MODE" = "success" ]
            }
            tail_logs_all_services() { return 0; }
            API_PORT=8787
            WEB_PORT=8080
            check_deployment_health statechecker none 0 10m 20
        '''

        failed = run_bash(harness, HEALTH_CHECK, "failure", check=False)
        healthy = run_bash(harness, HEALTH_CHECK, "success", check=False)

        self.assertNotEqual(failed.returncode, 0)
        self.assertIn("endpoint is unreachable or unhealthy", failed.stderr)
        self.assertEqual(healthy.returncode, 0, healthy.stderr)
        self.assertIn("Deployment is converged", healthy.stdout)

    def test_readiness_wait_stops_after_successful_attempt(self) -> None:
        """Stop polling as soon as startup becomes fully ready."""

        process = run_bash(
            r'''
                source "$1"
                attempts=0
                sleep() { :; }
                _deployment_ready_for_final_health_check() {
                    attempts=$((attempts + 1))
                    [ "$attempts" -ge 3 ]
                }
                wait_for_deployment_readiness statechecker traefik 5 10
                printf 'attempts=%s\n' "$attempts"
            ''',
            HEALTH_CHECK,
        )

        self.assertIn("Readiness attempt 3/5", process.stdout)
        self.assertIn("Deployment became ready on attempt 3/5", process.stdout)
        self.assertIn("attempts=3", process.stdout)

    def test_readiness_requires_swarm_and_external_endpoints(self) -> None:
        """Do not finalize while either Swarm or public HTTPS is unavailable."""

        harness = r'''
            source "$1"
            source "$2"
            RUNTIME_STATE="$3"
            CURL_STATE="$4"
            _get_stack_runtime_state() { printf '%s\n' "$RUNTIME_STATE"; }
            curl() { [ "$CURL_STATE" = "success" ]; }
            API_DOMAIN=api.statechecker.example.test
            WEB_DOMAIN=statechecker.example.test
            _deployment_ready_for_final_health_check statechecker traefik
        '''

        services_starting = run_bash(
            harness,
            DOCKER_HELPERS,
            HEALTH_CHECK,
            "not-ready",
            "success",
            check=False,
        )
        tls_starting = run_bash(
            harness,
            DOCKER_HELPERS,
            HEALTH_CHECK,
            "running",
            "failure",
            check=False,
        )
        ready = run_bash(
            harness,
            DOCKER_HELPERS,
            HEALTH_CHECK,
            "running",
            "success",
            check=False,
        )

        self.assertNotEqual(services_starting.returncode, 0)
        self.assertNotEqual(tls_starting.returncode, 0)
        self.assertEqual(ready.returncode, 0)

    def test_readiness_wait_is_bounded(self) -> None:
        """Finish with a warning when readiness never converges."""

        process = run_bash(
            r'''
                source "$1"
                attempts=0
                sleep() { :; }
                _deployment_ready_for_final_health_check() {
                    attempts=$((attempts + 1))
                    return 1
                }
                wait_for_deployment_readiness statechecker traefik 3 10
                status=$?
                printf 'attempts=%s\n' "$attempts"
                exit "$status"
            ''',
            HEALTH_CHECK,
            check=False,
        )

        self.assertNotEqual(process.returncode, 0)
        self.assertIn("Readiness attempt 3/3", process.stdout)
        self.assertIn("did not become ready after 3 attempts", process.stdout)
        self.assertIn("attempts=3", process.stdout)


@unittest.skipUnless(os.name == "posix" and shutil.which("bash"), "POSIX Bash required")
class ImageUpdateMenuTests(unittest.TestCase):
    """Verify paired image updates without contacting Docker or production."""

    def run_image_update(
        self,
        mode: str,
        new_tag: str = "3.0.2",
        api_tag: str = "3.0.1",
        web_tag: str = "3.0.1",
    ) -> tuple[subprocess.CompletedProcess[str], str, list[str]]:
        """Run menu choice 3 against a disposable env file and Docker stub."""

        with tempfile.TemporaryDirectory() as temporary_directory:
            directory = Path(temporary_directory)
            environment_file = directory / ".env"
            environment_file.write_text(
                "STACK_NAME=statechecker\n"
                "IMAGE_NAME=sokrates1989/statechecker\n"
                f"IMAGE_VERSION={api_tag}\n"
                "WEB_IMAGE_NAME=sokrates1989/statechecker-web\n"
                f"WEB_IMAGE_VERSION={web_tag}\n",
                encoding="utf-8",
            )
            events_file = directory / "docker-events.txt"
            process = run_bash(
                r'''
                    source "$1"
                    cd "$2"
                    MODE="$3"
                    NEW_TAG="$4"
                    EVENTS_FILE="$5"
                    prompt_number=0
                    read_prompt() {
                        prompt_number=$((prompt_number + 1))
                        case "$prompt_number" in
                            1) printf -v "$2" '%s' 3 ;;
                            2) printf -v "$2" '%s' "$NEW_TAG" ;;
                            3) printf -v "$2" '%s' y ;;
                        esac
                    }
                    docker() {
                        case "$1 $2" in
                            'service inspect') return 0 ;;
                            'pull '*)
                                printf '%s\n' "$*" >> "$EVENTS_FILE"
                                if [ "$MODE" = 'pull-fails' ] &&
                                    [[ "$2" == *statechecker-web* ]]; then
                                    return 1
                                fi
                                return 0
                                ;;
                            'service update')
                                printf '%s\n' "$*" >> "$EVENTS_FILE"
                                if [ "$MODE" = 'check-fails' ] &&
                                    [[ "${*: -1}" == statechecker_check ]]; then
                                    return 1
                                fi
                                return 0
                                ;;
                        esac
                        return 1
                    }
                    if [ "$MODE" = 'health-fails' ]; then
                        wait_for_deployment_readiness() { return 1; }
                        check_deployment_health() { return 1; }
                    fi
                    update_images_menu
                ''',
                MENU_HANDLERS,
                directory,
                mode,
                new_tag,
                events_file,
                check=False,
            )
            events = (
                events_file.read_text(encoding="utf-8").splitlines()
                if events_file.exists()
                else []
            )
            return process, environment_file.read_text(encoding="utf-8"), events

    def test_paired_choice_updates_three_services_and_both_env_versions(self) -> None:
        """Use one tag for API, checker, and web, then persist it twice."""

        process, environment, events = self.run_image_update("success")
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIn("3) API/CHECK + WEB images (one tag)", process.stdout)
        self.assertIn('IMAGE_VERSION="3.0.2"', environment)
        self.assertIn('WEB_IMAGE_VERSION="3.0.2"', environment)
        self.assertTrue(events[0].startswith("pull "))
        self.assertTrue(events[1].startswith("pull "))
        updates = [event for event in events if event.startswith("service update")]
        self.assertEqual(len(updates), 3)
        self.assertIn("statechecker_api", updates[0])
        self.assertIn("statechecker_check", updates[1])
        self.assertIn("statechecker_web", updates[2])
        self.assertIn("sokrates1989/statechecker-web:3.0.2", updates[2])

    def test_paired_choice_requires_one_tag_when_current_tags_differ(self) -> None:
        """Allow a deliberate shared tag after a previously split rollout."""

        process, environment, events = self.run_image_update(
            "success", web_tag="3.0.0"
        )
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIn('IMAGE_VERSION="3.0.2"', environment)
        self.assertIn('WEB_IMAGE_VERSION="3.0.2"', environment)
        self.assertEqual(
            sum(event.startswith("service update") for event in events), 3
        )

    def test_paired_choice_stops_before_updates_when_web_pull_fails(self) -> None:
        """Preserve both old versions if either image is unavailable."""

        process, environment, events = self.run_image_update("pull-fails")
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("Could not pull", process.stdout)
        self.assertFalse(any(event.startswith("service update") for event in events))
        self.assertIn("IMAGE_VERSION=3.0.1", environment)
        self.assertIn("WEB_IMAGE_VERSION=3.0.1", environment)

    def test_paired_choice_reports_partial_service_failure(self) -> None:
        """Do not save a shared tag if the checker update fails after API."""

        process, environment, events = self.run_image_update("check-fails")
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("Earlier services may already be updated", process.stdout)
        self.assertFalse(any("statechecker_web" in event for event in events if event.startswith("service update")))
        self.assertIn("IMAGE_VERSION=3.0.1", environment)
        self.assertIn("WEB_IMAGE_VERSION=3.0.1", environment)

    def test_paired_choice_rejects_latest_and_ambiguous_blank(self) -> None:
        """Require an explicit immutable-intent tag before contacting Docker."""

        latest, _, latest_events = self.run_image_update("success", new_tag="latest")
        self.assertNotEqual(latest.returncode, 0)
        self.assertIn("not latest", latest.stdout)
        self.assertEqual(latest_events, [])

        blank, _, blank_events = self.run_image_update(
            "success", new_tag="", web_tag="3.0.0"
        )
        self.assertNotEqual(blank.returncode, 0)
        self.assertIn("current image tags differ", blank.stdout)
        self.assertEqual(blank_events, [])

    def test_paired_choice_reports_failed_health_after_service_updates(self) -> None:
        """Do not claim a healthy deployment when post-update checks fail."""

        process, environment, events = self.run_image_update("health-fails")
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(
            sum(event.startswith("service update") for event in events), 3
        )
        self.assertIn('IMAGE_VERSION="3.0.2"', environment)
        self.assertIn('WEB_IMAGE_VERSION="3.0.2"', environment)
        self.assertIn("deployment is not healthy", process.stdout)

    def test_image_menu_locales_have_matching_keys(self) -> None:
        """Keep the new CLI's English and German message sets complete."""

        process = run_bash(
            r'''
                source "$1"
                [ "${#STATECHECKER_IMAGE_MENU_EN[@]}" -eq "${#STATECHECKER_IMAGE_MENU_DE[@]}" ] || exit 1
                for key in "${!STATECHECKER_IMAGE_MENU_EN[@]}"; do
                    [ -n "${STATECHECKER_IMAGE_MENU_DE[$key]:-}" ] || exit 1
                    en_without_slots="${STATECHECKER_IMAGE_MENU_EN[$key]//%s/}"
                    de_without_slots="${STATECHECKER_IMAGE_MENU_DE[$key]//%s/}"
                    en_slots=$(( (${#STATECHECKER_IMAGE_MENU_EN[$key]} - ${#en_without_slots}) / 2 ))
                    de_slots=$(( (${#STATECHECKER_IMAGE_MENU_DE[$key]} - ${#de_without_slots}) / 2 ))
                    [ "$en_slots" -eq "$de_slots" ] || exit 1
                done
                LC_ALL=de_DE.UTF-8 menu_image_message both_choice
                LC_ALL=fr_FR.UTF-8 menu_image_message both_choice
            ''',
            SETUP_DIRECTORY / "modules" / "menu_image_i18n.sh",
        )
        self.assertIn("API/CHECK- und WEB-Images", process.stdout)
        self.assertIn("API/CHECK + WEB images", process.stdout)


if __name__ == "__main__":
    unittest.main()
