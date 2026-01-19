#!/bin/bash

# menu_formatting.sh
# Shared formatting helpers for menu output.
# Safe to source multiple times.

# _box_rule
# Prints a horizontal rule for the overview box.
_box_rule() {
    local width=68
    printf '+%*s+\n' "$width" '' | tr ' ' '-'
}

# _box_line
# Prints a padded line inside the overview box.
#
# Arguments:
# - $1: line contents
_box_line() {
    local text="$1"
    local width=66
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
    local text="$1"
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
