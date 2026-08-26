#!/bin/bash
# ==============================================================================
# git_helpers.sh - Safe repository status and self-update helpers
# ==============================================================================
#
# The interactive quick-start menu uses these helpers to compare the current
# checkout with its configured origin and to apply fast-forward-only updates.
# Local changes, unexpected branches/remotes, detached HEADs, and diverged
# history deliberately block self-update.
# ==============================================================================

GIT_HELPERS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_REPOSITORY_ROOT="$(cd "${GIT_HELPERS_DIR}/../.." && pwd)"

if ! declare -F _menu_colorize >/dev/null 2>&1 &&
    [ -f "${GIT_HELPERS_DIR}/menu_formatting.sh" ]; then
    # shellcheck source=/dev/null
    source "${GIT_HELPERS_DIR}/menu_formatting.sh"
fi

# Public status values include: not-checked, up-to-date, behind, ahead,
# diverged, dirty, detached, unexpected-origin, unexpected-branch,
# unexpected-upstream, remote-unavailable, not-git, and error.
_GIT_UPDATE_STATUS="not-checked"
_GIT_UPDATE_BASE_STATUS="not-checked"
_GIT_UPDATE_BEHIND_COUNT="0"
_GIT_UPDATE_AHEAD_COUNT="0"
_GIT_UPDATE_BRANCH=""
_GIT_UPDATE_LAST_CHECK_EPOCH="0"

_git_repo_command() {
    git -C "$GIT_REPOSITORY_ROOT" "$@"
}

_git_print_message() {
    _menu_colorize "$1" "$2"
    printf '\n'
}

_git_repository_identifier() {
    local repository_url
    repository_url="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    repository_url="${repository_url%.git}"
    repository_url="${repository_url%/}"

    case "$repository_url" in
        git@github.com:*) repository_url="${repository_url#git@github.com:}" ;;
        ssh://git@github.com/*) repository_url="${repository_url#ssh://git@github.com/}" ;;
        https://github.com/*) repository_url="${repository_url#https://github.com/}" ;;
        http://github.com/*) repository_url="${repository_url#http://github.com/}" ;;
    esac

    printf '%s' "$repository_url"
}

_git_origin_is_expected() {
    local origin_url origin_identifier expected expected_identifier
    origin_url="$(_git_repo_command remote get-url origin 2>/dev/null)" || return 1
    origin_identifier="$(_git_repository_identifier "$origin_url")"

    for expected in ${GIT_EXPECTED_REPOSITORIES:-}; do
        expected_identifier="$(_git_repository_identifier "$expected")"
        if [ -n "$expected_identifier" ] &&
            [ "$origin_identifier" = "$expected_identifier" ]; then
            return 0
        fi
    done

    return 1
}

_git_fetch_origin() {
    local timeout_seconds="${GIT_FETCH_TIMEOUT_SECONDS:-8}"
    case "$timeout_seconds" in
        ''|*[!0-9]*) timeout_seconds=8 ;;
    esac

    if [ "$timeout_seconds" -gt 0 ] && command -v timeout >/dev/null 2>&1; then
        GIT_TERMINAL_PROMPT=0 timeout "$timeout_seconds" \
            git -C "$GIT_REPOSITORY_ROOT" fetch --quiet --prune origin
    else
        GIT_TERMINAL_PROMPT=0 _git_repo_command fetch --quiet --prune origin
    fi
}

# check_git_updates
# Fetches remote-tracking metadata and classifies the checkout state.
#
# Arguments:
# - $1: pass "force" to bypass the in-process cache
check_git_updates() {
    local force="${1:-}"
    local now_seconds ttl_seconds
    now_seconds="$(date +%s 2>/dev/null || printf '0')"
    ttl_seconds="${GIT_UPDATE_CHECK_TTL_SECONDS:-300}"
    case "$ttl_seconds" in
        ''|*[!0-9]*) ttl_seconds=300 ;;
    esac

    if [ "$force" != "force" ] && [ "$_GIT_UPDATE_LAST_CHECK_EPOCH" -gt 0 ] &&
        [ "$now_seconds" -gt 0 ] &&
        [ $((now_seconds - _GIT_UPDATE_LAST_CHECK_EPOCH)) -lt "$ttl_seconds" ]; then
        return 0
    fi

    _GIT_UPDATE_STATUS="error"
    _GIT_UPDATE_BASE_STATUS="error"
    _GIT_UPDATE_BEHIND_COUNT="0"
    _GIT_UPDATE_AHEAD_COUNT="0"
    _GIT_UPDATE_BRANCH=""
    _GIT_UPDATE_LAST_CHECK_EPOCH="$now_seconds"

    if ! command -v git >/dev/null 2>&1; then
        _GIT_UPDATE_STATUS="not-git"
        _GIT_UPDATE_BASE_STATUS="not-git"
        return 0
    fi

    if [ "$(_git_repo_command rev-parse --is-inside-work-tree 2>/dev/null)" != "true" ]; then
        _GIT_UPDATE_STATUS="not-git"
        _GIT_UPDATE_BASE_STATUS="not-git"
        return 0
    fi

    if ! _git_origin_is_expected; then
        _GIT_UPDATE_STATUS="unexpected-origin"
        _GIT_UPDATE_BASE_STATUS="unexpected-origin"
        return 0
    fi

    _GIT_UPDATE_BRANCH="$(_git_repo_command symbolic-ref --short -q HEAD 2>/dev/null || true)"
    if [ -z "$_GIT_UPDATE_BRANCH" ]; then
        _GIT_UPDATE_STATUS="detached"
        _GIT_UPDATE_BASE_STATUS="detached"
        return 0
    fi

    if [ -n "${GIT_EXPECTED_BRANCH:-}" ] &&
        [ "$_GIT_UPDATE_BRANCH" != "$GIT_EXPECTED_BRANCH" ]; then
        _GIT_UPDATE_STATUS="unexpected-branch"
        _GIT_UPDATE_BASE_STATUS="unexpected-branch"
        return 0
    fi

    local upstream
    upstream="$(_git_repo_command rev-parse --abbrev-ref --symbolic-full-name \
        '@{upstream}' 2>/dev/null || true)"
    if [ "$upstream" != "origin/${_GIT_UPDATE_BRANCH}" ]; then
        _GIT_UPDATE_STATUS="unexpected-upstream"
        _GIT_UPDATE_BASE_STATUS="unexpected-upstream"
        return 0
    fi

    local dirty_output dirty
    dirty_output="$(_git_repo_command status --porcelain --untracked-files=normal \
        2>/dev/null)" || return 0
    dirty=false
    [ -n "$dirty_output" ] && dirty=true

    if ! _git_fetch_origin 2>/dev/null; then
        _GIT_UPDATE_BASE_STATUS="remote-unavailable"
        if [ "$dirty" = true ]; then
            _GIT_UPDATE_STATUS="dirty"
        else
            _GIT_UPDATE_STATUS="remote-unavailable"
        fi
        return 0
    fi

    local local_head remote_head merge_base base_status
    local_head="$(_git_repo_command rev-parse HEAD 2>/dev/null || true)"
    remote_head="$(_git_repo_command rev-parse "$upstream" 2>/dev/null || true)"
    if [ -z "$local_head" ] || [ -z "$remote_head" ]; then
        return 0
    fi

    if [ "$local_head" = "$remote_head" ]; then
        base_status="up-to-date"
    else
        merge_base="$(_git_repo_command merge-base "$local_head" "$remote_head" \
            2>/dev/null || true)"
        if [ "$merge_base" = "$local_head" ]; then
            base_status="behind"
            _GIT_UPDATE_BEHIND_COUNT="$(_git_repo_command rev-list --count \
                "${local_head}..${remote_head}" 2>/dev/null || printf '?')"
        elif [ "$merge_base" = "$remote_head" ]; then
            base_status="ahead"
            _GIT_UPDATE_AHEAD_COUNT="$(_git_repo_command rev-list --count \
                "${remote_head}..${local_head}" 2>/dev/null || printf '?')"
        else
            base_status="diverged"
        fi
    fi

    _GIT_UPDATE_BASE_STATUS="$base_status"
    if [ "$dirty" = true ]; then
        _GIT_UPDATE_STATUS="dirty"
    else
        _GIT_UPDATE_STATUS="$base_status"
    fi
}

# show_git_status_line
# Prints the semantic repository state used in the boxed overview.
show_git_status_line() {
    case "$_GIT_UPDATE_STATUS" in
        up-to-date)
            echo "Repo     : $(_menu_colorize ok '[OK] up to date')"
            ;;
        behind)
            echo "Repo     : $(_menu_colorize warning "[WARN] ${_GIT_UPDATE_BEHIND_COUNT} update(s) available")"
            ;;
        ahead)
            echo "Repo     : $(_menu_colorize warning "[WARN] ${_GIT_UPDATE_AHEAD_COUNT} local commit(s) ahead")"
            ;;
        diverged)
            echo "Repo     : $(_menu_colorize error '[ERROR] local and remote history diverged')"
            ;;
        dirty)
            if [ "$_GIT_UPDATE_BASE_STATUS" = "behind" ]; then
                echo "Repo     : $(_menu_colorize warning "[WARN] local changes; ${_GIT_UPDATE_BEHIND_COUNT} update(s) waiting")"
            elif [ "$_GIT_UPDATE_BASE_STATUS" = "remote-unavailable" ]; then
                echo "Repo     : $(_menu_colorize warning '[WARN] local changes; remote check unavailable')"
            else
                echo "Repo     : $(_menu_colorize warning '[WARN] local changes; self-update blocked')"
            fi
            ;;
        detached)
            echo "Repo     : $(_menu_colorize error '[ERROR] detached HEAD; self-update blocked')"
            ;;
        unexpected-origin)
            echo "Repo     : $(_menu_colorize error '[ERROR] unexpected origin; self-update blocked')"
            ;;
        unexpected-branch)
            echo "Repo     : $(_menu_colorize error "[ERROR] branch ${_GIT_UPDATE_BRANCH}; expected ${GIT_EXPECTED_BRANCH}")"
            ;;
        unexpected-upstream)
            echo "Repo     : $(_menu_colorize error '[ERROR] missing expected origin upstream')"
            ;;
        remote-unavailable)
            echo "Repo     : $(_menu_colorize warning '[WARN] remote check unavailable')"
            ;;
        not-git)
            echo "Repo     : $(_menu_colorize warning '[WARN] not a Git checkout')"
            ;;
        error)
            echo "Repo     : $(_menu_colorize warning '[WARN] repository check failed')"
            ;;
        *)
            echo "Repo     : $(_menu_colorize info '[INFO] not checked')"
            ;;
    esac
}

# refresh_git_update_status
# Forces a remote state refresh and prints the resulting overview line.
refresh_git_update_status() {
    check_git_updates force
    show_git_status_line
}

# handle_git_pull
# Applies a clean fast-forward-only update and restarts quick-start.sh.
handle_git_pull() {
    check_git_updates force

    case "$_GIT_UPDATE_STATUS" in
        behind) ;;
        up-to-date)
            _git_print_message ok '[OK] Repository is already up to date.'
            return 0
            ;;
        dirty)
            _git_print_message error '[ERROR] Update blocked: commit, stash, or remove local changes first.'
            return 1
            ;;
        ahead)
            _git_print_message warning '[WARN] No update applied: local commits are ahead of origin.'
            return 1
            ;;
        diverged)
            _git_print_message error '[ERROR] Update blocked: local and remote history diverged.'
            return 1
            ;;
        detached)
            _git_print_message error '[ERROR] Update blocked: checkout is in detached HEAD state.'
            return 1
            ;;
        unexpected-origin)
            _git_print_message error '[ERROR] Update blocked: origin does not match this deployment repository.'
            return 1
            ;;
        unexpected-branch)
            _git_print_message error "[ERROR] Update blocked: switch to ${GIT_EXPECTED_BRANCH} first."
            return 1
            ;;
        unexpected-upstream)
            _git_print_message error '[ERROR] Update blocked: expected origin upstream is not configured.'
            return 1
            ;;
        remote-unavailable)
            _git_print_message warning '[WARN] Update not attempted: origin is currently unavailable.'
            return 1
            ;;
        *)
            _git_print_message error '[ERROR] Update blocked: repository state is unsafe or unknown.'
            return 1
            ;;
    esac

    local old_head new_head restart_script
    old_head="$(_git_repo_command rev-parse --short=12 HEAD 2>/dev/null || true)"

    echo ""
    _git_print_message info '[UPDATE] Applying fast-forward repository update...'
    if ! GIT_TERMINAL_PROMPT=0 _git_repo_command pull --ff-only --quiet; then
        _git_print_message error '[ERROR] Git pull failed; the checkout was not rewritten.'
        return 1
    fi

    new_head="$(_git_repo_command rev-parse --short=12 HEAD 2>/dev/null || true)"
    _GIT_UPDATE_STATUS="up-to-date"
    _GIT_UPDATE_BASE_STATUS="up-to-date"
    _GIT_UPDATE_BEHIND_COUNT="0"
    _git_print_message ok "[OK] Repository updated: ${old_head:-unknown} -> ${new_head:-unknown}"

    if [ "${GIT_RESTART_AFTER_UPDATE:-true}" = "false" ]; then
        return 0
    fi

    restart_script="${GIT_REPOSITORY_ROOT}/quick-start.sh"
    if [ ! -f "$restart_script" ]; then
        _git_print_message warning "[WARN] Restart manually; quick-start.sh was not found at ${restart_script}"
        return 1
    fi

    _git_print_message info '[INFO] Restarting quick-start.sh with the updated code...'
    cd "$GIT_REPOSITORY_ROOT" || return 1
    if [ -x "$restart_script" ]; then
        exec "$restart_script"
    else
        exec bash "$restart_script"
    fi
}
