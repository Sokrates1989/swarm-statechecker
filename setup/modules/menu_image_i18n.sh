#!/bin/bash
# Image-update menu translations without an extra runtime dependency.

IMAGE_MENU_I18N_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${IMAGE_MENU_I18N_DIR}/../locales/en.sh"
# shellcheck source=/dev/null
source "${IMAGE_MENU_I18N_DIR}/../locales/de.sh"

# menu_image_message
# Print an image-update menu message, interpolating positional values.
# Falls back to English for unsupported locales or missing German keys.
# Arguments: $1 semantic key; remaining arguments are printf values.
menu_image_message() {
    local key="$1"
    shift
    local format="${STATECHECKER_IMAGE_MENU_EN[$key]:-}"
    case "${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}" in
        de*) format="${STATECHECKER_IMAGE_MENU_DE[$key]:-$format}" ;;
    esac
    if [ -z "$format" ]; then
        printf 'Missing image-menu translation: %s\n' "$key" >&2
        return 1
    fi
    # Catalogs are trusted repository files; placeholders are validated in tests.
    # shellcheck disable=SC2059
    printf "$format" "$@"
}
