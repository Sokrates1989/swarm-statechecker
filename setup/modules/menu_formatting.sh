#!/bin/bash

# menu_formatting.sh
# Shared formatting helpers for menu output.
# Safe to source multiple times.

# Cache terminal color capability before command substitutions redirect stdout.
# NO_COLOR remains the standard operator override.
if [ -z "${_MENU_COLOR_ENABLED+x}" ]; then
    _MENU_COLOR_ENABLED=false
    if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] &&
        [ "${TERM:-dumb}" != "dumb" ]; then
        _MENU_COLOR_ENABLED=true
    fi
fi

# Keep service images and status notes inside the overview border on normal
# server terminals. Callers may override this before sourcing the module.
MENU_BOX_TEXT_WIDTH="${MENU_BOX_TEXT_WIDTH:-92}"

# _menu_colorize
# Applies a semantic terminal color without changing plain captured output.
#
# Arguments:
# - $1: ok, warning, error, info, or off
# - $2: text to render
_menu_colorize() {
    local level="$1"
    local text="$2"
    local code=""

    if [ "${_MENU_COLOR_ENABLED:-false}" != "true" ]; then
        printf '%s' "$text"
        return 0
    fi
    case "$level" in
        ok) code=$'\033[32m' ;;
        warning) code=$'\033[33m' ;;
        error) code=$'\033[31m' ;;
        info) code=$'\033[36m' ;;
        off) code=$'\033[90m' ;;
        *) printf '%s' "$text"; return 0 ;;
    esac
    printf '%b%s%b' "$code" "$text" $'\033[0m'
}

# _menu_semantic_level_for_text
# Maps conventional operator-status markers to their shared semantic color.
# Error markers take precedence when a line contains more than one status.
#
# Arguments:
# - $1: complete line of operator-facing text
#
# Output:
# - error, warning, ok, info, or off; no output for ordinary text
_menu_semantic_level_for_text() {
    local text="$1"

    case "$text" in
        *'[ERROR]'*|*'[FAIL]'*|*'[FAILED]'*|*'ERROR:'*|*'Error:'*|*'❌'*)
            printf '%s' 'error'
            ;;
        *'[WARN]'*|*'WARNING:'*|*'Warning:'*|*'[UPDATE]'*)
            printf '%s' 'warning'
            ;;
        *'[UNKNOWN]'*|*'[STALE]'*|*'[MISSING]'*|*'⚠️'*)
            printf '%s' 'warning'
            ;;
        *'[OK]'*|*'[SUCCESS]'*|*'SUCCESS:'*|*'Success:'*|*'✅'*)
            printf '%s' 'ok'
            ;;
        *'[INFO]'*|*'[CHECK]'*|*'[WAIT]'*|*'ℹ️'*) printf '%s' 'info' ;;
        *'[OFF]'*|*'[IGNORED]'*) printf '%s' 'off' ;;
        *) return 1 ;;
    esac
}

# echo
# Preserves Bash's normal echo behavior while automatically colorizing complete
# semantic status lines on an interactive terminal. Redirected files, command
# substitutions, captured tests, NO_COLOR output, option-bearing echo calls,
# and text already containing ANSI escapes remain byte-for-byte plain.
#
# Arguments:
# - all arguments accepted by Bash's echo builtin
#
# Returns:
# - the Bash echo builtin's status
echo() {
    local level=""
    local text="$*"

    if [ "$#" -gt 0 ] && [[ "${1:-}" != -* ]] && [ -t 1 ] &&
        [ "${_MENU_COLOR_ENABLED:-false}" = "true" ] &&
        [ -z "${NO_COLOR:-}" ] && [[ "$text" != *$'\033['* ]]; then
        level="$(_menu_semantic_level_for_text "$text")" || level=""
        if [ -n "$level" ]; then
            builtin printf '%s\n' "$(_menu_colorize "$level" "$text")"
            return $?
        fi
    fi
    builtin echo "$@"
}

# _menu_colorize_stream
# Re-emits a subprocess stream through the semantic echo formatter. Place this
# after a plain-text tee when logs must remain free of ANSI escape sequences.
#
# Input:
# - newline-delimited operator output on stdin
#
# Output:
# - identical lines, colorized only when the final destination is a TTY
_menu_colorize_stream() {
    local line=""

    while IFS= read -r line || [ -n "$line" ]; do
        echo "$line"
    done
}

# _menu_heading
# Renders a menu section heading using the shared informational color.
#
# Arguments:
# - $1: heading text
_menu_heading() {
    _menu_colorize info "$1"
}

# _strip_menu_colors
# Removes ANSI SGR sequences before box-width calculation.
#
# Arguments:
# - $1: potentially colorized text
#
# Output:
# - plain text with terminal color sequences removed
_strip_menu_colors() {
    local plain="$1"
    local pattern=$'\033''\[[0-9;]*m'

    while [[ "$plain" =~ $pattern ]]; do
        plain="${plain/"${BASH_REMATCH[0]}"/}"
    done
    printf '%s' "$plain"
}

# _box_rule
# Prints a horizontal rule for the overview box.
_box_rule() {
    local width=$((MENU_BOX_TEXT_WIDTH + 2))
    printf '+%*s+\n' "$width" '' | tr ' ' '-'
}

# _box_line
# Prints a padded line inside the overview box.
#
# Arguments:
# - $1: line contents
_box_line() {
    local text="$1"
    local width="$MENU_BOX_TEXT_WIDTH"
    local display_len
    display_len=$(_calc_display_width "$text")
    local pad=$((width - display_len))
    if [ "$pad" -lt 0 ]; then
        pad=0
    fi
    printf "| %s%*s |\n" "$text" "$pad" ""
}

# _icon_display_extra
# Estimates extra columns required for emoji icons.
#
# Arguments:
# - $1: line contents
# - $2: icon to check
# - $3: display width to assume for the icon
# Output:
# - prints the extra columns needed (may be negative)
_icon_display_extra() {
    local text="$1"
    local icon="$2"
    local display_width="$3"
    local icon_len=${#icon}

    if [ "$icon_len" -le 0 ]; then
        echo 0
        return 0
    fi

    local without="${text//${icon}/}"
    local diff=$(( ${#text} - ${#without} ))
    local count=$((diff / icon_len))
    local extra=$((count * (display_width - icon_len)))
    echo "$extra"
}

# _calc_display_width
# Estimates display width by accounting for emoji double-width rendering.
#
# Arguments:
# - $1: line contents
# Output:
# - prints estimated display width
_calc_display_width() {
    local text
    text="$(_strip_menu_colors "$1")"
    local base_len=${#text}
    local extra=0

    extra=$((extra + $(_icon_display_extra "$text" "✅" 2)))
    extra=$((extra + $(_icon_display_extra "$text" "⚠️" 1)))
    extra=$((extra + $(_icon_display_extra "$text" "❌" 2)))
    extra=$((extra + $(_icon_display_extra "$text" "⏹️" 1)))

    echo $((base_len + extra))
}

# _box_line_list
# Prints a list item line with reduced indent.
#
# Arguments:
# - $1: line contents (without leading spaces)
_box_line_list() {
    _box_line " - $1"
}
