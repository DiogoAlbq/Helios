#!/usr/bin/env bash
# Helios installer — installs helios, hx symlink, and optional alias symlinks
# Run as user (installs to ~/.local/bin) or root (installs to /usr/local/bin)

set -euo pipefail

readonly VERSION="1.0.0"
readonly PROG_NAME="helios"

PREFIX=""
CREATE_ALIASES=false
DRY_RUN=false
FORCE=false

usage() {
    cat <<EOF
Helios Installer v$VERSION

Usage: $0 [options]

Options:
  --prefix <path>       Install directory (default: ~/.local/bin for user, /usr/local/bin for root)
  --create-aliases      Create symlinks for aliases defined in config (or example config)
  --dry-run             Show what would be done without making changes
  --force               Overwrite existing files (use with caution)
  --help, -h            Show this help

Examples:
  $0                           # Install to ~/.local/bin
  sudo $0                      # Install to /usr/local/bin
  $0 --prefix ~/bin            # Custom install directory
  $0 --create-aliases          # Also create alias symlinks from config
EOF
}

log_info() {
    printf '[helios-install] %s\n' "$*" >&2
}

log_warn() {
    printf '[helios-install][warn] %s\n' "$*" >&2
}

log_error() {
    printf '[helios-install][error] %s\n' "$*" >&2
}

die() {
    log_error "$*"
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix)
            [[ $# -lt 2 ]] && die "--prefix requires a path"
            PREFIX="$2"
            shift 2
            ;;
        --prefix=*)
            PREFIX="${1#*=}"
            shift
            ;;
        --create-aliases)
            CREATE_ALIASES=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1"
            ;;
    esac
done

# Determine install prefix
if [[ -z "$PREFIX" ]]; then
    if [[ $EUID -eq 0 ]]; then
        PREFIX="/usr/local/bin"
    else
        PREFIX="$HOME/.local/bin"
    fi
fi

# Expand tilde
PREFIX="${PREFIX/#\~/$HOME}"

log_info "Installing Helios v$VERSION to $PREFIX"

# Source directory (where this script lives)
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELIOS_BIN="$SRC_DIR/bin/helios"
CONFIG_EXAMPLE="$SRC_DIR/helios.conf.example"

[[ -f "$HELIOS_BIN" ]] || die "Source binary not found: $HELIOS_BIN"
[[ -f "$CONFIG_EXAMPLE" ]] || die "Example config not found: $CONFIG_EXAMPLE"

# Create install directory
if $DRY_RUN; then
    log_info "DRY-RUN: Would create directory: $PREFIX"
else
    mkdir -p "$PREFIX" || die "Failed to create $PREFIX"
fi

# Install main binary
DEST_BIN="$PREFIX/helios"

if $DRY_RUN; then
    log_info "DRY-RUN: Would install $HELIOS_BIN -> $DEST_BIN"
else
    cp -f "$HELIOS_BIN" "$DEST_BIN" || die "Failed to copy binary"
    chmod 755 "$DEST_BIN" || die "Failed to chmod binary"
    log_info "Installed: $DEST_BIN"
fi

# Create hx symlink
HX_LINK="$PREFIX/hx"
if [[ -L "$HX_LINK" ]]; then
    current_target=$(readlink "$HX_LINK")
    if [[ "$current_target" != "$DEST_BIN" ]]; then
        if $FORCE; then
            if $DRY_RUN; then
                log_info "DRY-RUN: Would replace hx symlink"
            else
                rm -f "$HX_LINK"
                ln -s "$DEST_BIN" "$HX_LINK"
                log_info "Updated hx symlink"
            fi
        else
            log_warn "hx symlink exists with different target: $current_target (use --force to replace)"
        fi
    else
        log_info "hx symlink already correct"
    fi
elif [[ -e "$HX_LINK" ]]; then
    if $FORCE; then
        if $DRY_RUN; then
            log_info "DRY-RUN: Would replace $HX_LINK with symlink"
        else
            rm -f "$HX_LINK"
            ln -s "$DEST_BIN" "$HX_LINK"
            log_info "Created hx symlink (replaced existing file)"
        fi
    else
        die "hx exists and is not a symlink: $HX_LINK (use --force to overwrite)"
    fi
else
    if $DRY_RUN; then
        log_info "DRY-RUN: Would create hx symlink"
    else
        ln -s "$DEST_BIN" "$HX_LINK" || die "Failed to create hx symlink"
        log_info "Created hx symlink: $HX_LINK -> $DEST_BIN"
    fi
fi

# Create alias symlinks if requested
if $CREATE_ALIASES; then
    # Determine config to read aliases from
    CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/helios"
    CONFIG_FILE="$CONFIG_DIR/helios.conf"
    ALIAS_SOURCE=""

    if [[ -f "$CONFIG_FILE" ]]; then
        ALIAS_SOURCE="$CONFIG_FILE"
        log_info "Reading aliases from user config: $CONFIG_FILE"
    else
        ALIAS_SOURCE="$CONFIG_EXAMPLE"
        log_info "No user config found, reading aliases from example: $CONFIG_EXAMPLE"
    fi

    # Parse aliases from config (HELIOS_ALIAS_<name>)
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        [[ "${line:0:1}" == "#" ]] && continue

        if [[ "$line" =~ ^HELIOS_ALIAS_([A-Za-z0-9_-]+)=(.*)$ ]]; then
            alias_name="${BASH_REMATCH[1]}"
            alias_profiles="${BASH_REMATCH[2]}"
            # Strip quotes
            alias_profiles="${alias_profiles#\"}"
            alias_profiles="${alias_profiles%\"}"
            alias_profiles="${alias_profiles#\'}"
            alias_profiles="${alias_profiles%\'}"

            # Create three symlink variants
            for prefix in "helios-" "helios_alias_" "hx-"; do
                link_path="$PREFIX/${prefix}${alias_name}"
                if [[ -L "$link_path" ]]; then
                    current=$(readlink "$link_path")
                    if [[ "$current" != "$DEST_BIN" ]]; then
                        if $FORCE; then
                            if $DRY_RUN; then
                                log_info "DRY-RUN: Would replace $link_path"
                            else
                                rm -f "$link_path"
                                ln -s "$DEST_BIN" "$link_path"
                                log_info "Created alias symlink: $link_path"
                            fi
                        else
                            log_warn "Alias symlink $link_path exists with different target (skipped)"
                        fi
                    fi
                elif [[ -e "$link_path" ]]; then
                    if $FORCE; then
                        if $DRY_RUN; then
                            log_info "DRY-RUN: Would replace $link_path"
                        else
                            rm -f "$link_path"
                            ln -s "$DEST_BIN" "$link_path"
                            log_info "Created alias symlink (replaced): $link_path"
                        fi
                    else
                        log_warn "$link_path exists and is not a symlink (skipped)"
                    fi
                else
                    if $DRY_RUN; then
                        log_info "DRY-RUN: Would create $link_path"
                    else
                        ln -s "$DEST_BIN" "$link_path" || log_warn "Failed to create $link_path"
                        log_info "Created alias symlink: $link_path"
                    fi
                fi
            done
        fi
    done < "$ALIAS_SOURCE"
fi

# Copy example config if no user config exists
USER_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/helios"
USER_CONFIG_FILE="$USER_CONFIG_DIR/helios.conf"
if [[ ! -f "$USER_CONFIG_FILE" ]]; then
    if $DRY_RUN; then
        log_info "DRY-RUN: Would copy example config to $USER_CONFIG_FILE"
    else
        mkdir -p "$USER_CONFIG_DIR"
        cp "$CONFIG_EXAMPLE" "$USER_CONFIG_FILE" || log_warn "Failed to copy example config"
        log_info "Copied example config to $USER_CONFIG_FILE"
    fi
else
    log_info "User config already exists: $USER_CONFIG_FILE (not overwritten)"
fi

# Ensure install directory is in PATH
if [[ ":$PATH:" != *":$PREFIX:"* ]]; then
    path_line="export PATH=\"$PREFIX:\$PATH\""
    updated_rc=""
    for rc_file in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [[ -f "$rc_file" ]]; then
            if ! grep -Fq "$PREFIX" "$rc_file" 2>/dev/null; then
                if $DRY_RUN; then
                    log_info "DRY-RUN: Would add $PREFIX to PATH in $rc_file"
                else
                    printf '\n# Added by helios installer\n%s\n' "$path_line" >> "$rc_file"
                    log_info "Added $PREFIX to PATH in $rc_file"
                fi
            fi
            updated_rc="$rc_file"
        fi
    done

    if [[ -z "$updated_rc" ]]; then
        rc_file="$HOME/.profile"
        if ! grep -Fq "$PREFIX" "$rc_file" 2>/dev/null; then
            if $DRY_RUN; then
                log_info "DRY-RUN: Would add $PREFIX to PATH in $rc_file"
            else
                printf '\n# Added by helios installer\n%s\n' "$path_line" >> "$rc_file"
                log_info "Added $PREFIX to PATH in $rc_file"
            fi
        fi
        updated_rc="$rc_file"
    fi

    log_info "Run 'source $updated_rc' or open a new terminal to use helios/hx immediately"
fi

log_info "Installation complete!"
log_info "Run 'helios --help' or 'hx --help' to get started"