wizard_show_editor_instructions() {
    local editor="$1"

    echo ""
    if [[ "$editor" == "nano" ]]; then
        echo "Instructions for nano:"
        echo "  1. Edit the file"
        echo "  2. Press Ctrl+O to save"
        echo "  3. Press Enter to confirm"
        echo "  4. Press Ctrl+X to exit"
    elif [[ "$editor" == "vim" || "$editor" == "vi" ]]; then
        echo "Instructions for vim/vi:"
        echo "  1. Press 'i' to enter insert mode"
        echo "  2. Edit the file"
        echo "  3. Press Esc to exit insert mode"
        echo "  4. Type ':wq' and press Enter to save and quit"
    fi
    echo ""
}

wizard_load_saved_editor() {
    # wizard_load_saved_editor
    # Loads WIZARD_EDITOR from a persisted local file if not already set.
    #
    # Returns:
    # - 0 if editor is available (already set or loaded)
    # - 1 otherwise
    if [ -n "${WIZARD_EDITOR:-}" ]; then
        return 0
    fi

    if [ -f .wizard-editor ]; then
        local saved
        saved=$(cat .wizard-editor 2>/dev/null | tr -d '\r\n')
        case "$saved" in
            nano|vi|vim)
                WIZARD_EDITOR="$saved"
                return 0
                ;;
        esac
    fi

    return 1
}

wizard_save_editor() {
    # wizard_save_editor
    # Persists WIZARD_EDITOR selection into a local file for future runs.
    if [ -n "${WIZARD_EDITOR:-}" ]; then
        printf '%s\n' "$WIZARD_EDITOR" > .wizard-editor 2>/dev/null || true
    fi
}

wizard_choose_editor() {
    if wizard_load_saved_editor; then
        return 0
    fi

    while true; do
        echo "Which editor would you like to use?"
        echo "1) nano (easier for beginners)"
        echo "2) vi/vim (advanced)"
        echo ""
        read -p "Your choice (1-2) [1]: " editor_choice
        editor_choice="${editor_choice:-1}"

        case "$editor_choice" in
            1)
                if command -v nano >/dev/null 2>&1; then
                    WIZARD_EDITOR="nano"
                else
                    echo "[WARN] nano not found, falling back to vi"
                    WIZARD_EDITOR="vi"
                fi
                wizard_save_editor
                return 0
                ;;
            2)
                if command -v vim >/dev/null 2>&1; then
                    WIZARD_EDITOR="vim"
                elif command -v vi >/dev/null 2>&1; then
                    WIZARD_EDITOR="vi"
                else
                    echo "[ERROR] vi/vim not found"
                    return 1
                fi
                wizard_save_editor
                return 0
                ;;
            *)
                echo "[ERROR] Invalid choice"
                echo ""
                ;;
        esac
    done
}

wizard_edit_file() {
    local file="$1"
    local editor="$2"

    wizard_show_editor_instructions "$editor"
    read -p "Press Enter to open $file in $editor..." _
    echo ""

    "$editor" "$file"
    echo ""
    echo "[OK] File saved: $file"
    echo ""
}
