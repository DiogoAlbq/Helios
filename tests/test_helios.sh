#!/usr/bin/env bash
# Automated test suite for helios (runs in isolated temp dirs with mocked tools)

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly SRC_HELIOS_BIN="$REPO_ROOT/bin/helios"
readonly INSTALL_SH="$REPO_ROOT/install.sh"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    readonly PASS_COLOR=$'\033[32m'
    readonly FAIL_COLOR=$'\033[31m'
    readonly INFO_COLOR=$'\033[34m'
    readonly RESET_COLOR=$'\033[0m'
else
    readonly PASS_COLOR="" FAIL_COLOR="" INFO_COLOR="" RESET_COLOR=""
fi

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

TEST_ROOT=""
MOCK_BIN_DIR=""
HELIOS_BIN=""

setup_test_env() {
    TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/helios_test.XXXXXX")
    MOCK_BIN_DIR="$TEST_ROOT/mock_bin"
    local bin_dir="$TEST_ROOT/bin"
    mkdir -p "$MOCK_BIN_DIR" "$bin_dir"

    cp "$SRC_HELIOS_BIN" "$bin_dir/helios"
    chmod +x "$bin_dir/helios"
    HELIOS_BIN="$bin_dir/helios"

    export PATH="$MOCK_BIN_DIR:/usr/local/bin:/usr/bin:/bin"
    export XDG_CONFIG_HOME="$TEST_ROOT/config"
    export XDG_CACHE_HOME="$TEST_ROOT/cache"
    export HOME="$TEST_ROOT/home"
    mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$HOME"

    unset SteamAppId STEAM_APP_ID STEAM_COMPAT_DATA_PATH || true
}

teardown_test_env() {
    unset SteamAppId STEAM_APP_ID STEAM_COMPAT_DATA_PATH || true
    [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
    TEST_ROOT=""
}

run_test() {
    local name="$1"
    local func="$2"
    TESTS_RUN=$((TESTS_RUN + 1))
    printf '%s[RUN]%s %s\n' "$INFO_COLOR" "$RESET_COLOR" "$name"
    local rc=0
    set +e
    ( set -euo pipefail; "$func" )
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        printf '%s[PASS]%s %s\n' "$PASS_COLOR" "$RESET_COLOR" "$name"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        printf '%s[FAIL]%s %s\n' "$FAIL_COLOR" "$RESET_COLOR" "$name"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    [[ "$expected" == "$actual" ]] || {
        echo "  Expected: '$expected'" >&2
        echo "  Actual:   '$actual'" >&2
        [[ -n "$msg" ]] && echo "  $msg" >&2
        return 1
    }
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    [[ "$haystack" == *"$needle"* ]] || {
        echo "  Expected to contain: '$needle'" >&2
        echo "  In: '$haystack'" >&2
        [[ -n "$msg" ]] && echo "  $msg" >&2
        return 1
    }
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    [[ "$haystack" != *"$needle"* ]] || {
        echo "  Expected NOT to contain: '$needle'" >&2
        echo "  In: '$haystack'" >&2
        [[ -n "$msg" ]] && echo "  $msg" >&2
        return 1
    }
}

create_mock_nvidia_smi() {
    local gpu_name="$1"
    cat > "$MOCK_BIN_DIR/nvidia-smi" <<EOF
#!/usr/bin/env bash
case "\$1" in
    --query-gpu=name) echo "$gpu_name" ;;
    --query-gpu=driver_version) echo "550.00" ;;
    *) exit 1 ;;
esac
EOF
    chmod +x "$MOCK_BIN_DIR/nvidia-smi"
}

remove_mock_nvidia_smi() {
    rm -f "$MOCK_BIN_DIR/nvidia-smi"
}

create_mock_sha256sum() {
    cat > "$MOCK_BIN_DIR/sha256sum" <<'EOF'
#!/usr/bin/env bash
echo "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890  $1"
EOF
    chmod +x "$MOCK_BIN_DIR/sha256sum"
}

create_fake_steam_lib() {
    local base="$1"
    local appid="$2"
    local installdir="$3"
    shift 3
    local -a dlls=("$@")

    local steamapps="$base/steamapps"
    mkdir -p "$steamapps/common/$installdir"

    cat > "$steamapps/libraryfolders.vdf" <<EOF
"libraryfolders"
{
	"0"
	{
		"path"	"$base"
	}
	"1"
	{
		"path"	"$base/extra_lib"
	}
}
EOF

    cat > "$steamapps/appmanifest_${appid}.acf" <<EOF
"AppState"
{
	"appid"		"$appid"
	"installdir"	"$installdir"
}
EOF

    local dll
    for dll in "${dlls[@]}"; do
        echo "fake dll content" > "$steamapps/common/$installdir/$dll"
    done

    mkdir -p "$base/extra_lib/steamapps"
}

# Syntax

test_syntax_check() {
    bash -n "$SRC_HELIOS_BIN" || return 1
    bash -n "$INSTALL_SH" || return 1
    bash -n "${BASH_SOURCE[0]}" || return 1
}

# Subcommands

test_scan() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local output
    output=$("$HELIOS_BIN" scan 2>&1) || return 1
    assert_contains "$output" "helios v1.0.0"
    assert_contains "$output" "RTX 4080"
    assert_contains "$output" "ada"
    teardown_test_env
}

test_doctor_alias() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 3070"
    local output
    output=$("$HELIOS_BIN" doctor 2>&1) || return 1
    assert_contains "$output" "ampere"
    teardown_test_env
}

test_modes() {
    setup_test_env
    local output
    output=$("$HELIOS_BIN" modes 2>&1) || return 1
    assert_contains "$output" "BASE PROFILES:"
    assert_contains "$output" "META-PROFILES:"
    assert_contains "$output" "PROFILE ALGEBRA:"
    assert_contains "$output" "PRIORITY ORDER:"
    teardown_test_env
}

test_profiles_alias() {
    setup_test_env
    local output
    output=$("$HELIOS_BIN" profiles 2>&1) || return 1
    assert_contains "$output" "BASE PROFILES:"
    teardown_test_env
}

test_version() {
    setup_test_env
    local output
    output=$("$HELIOS_BIN" version 2>&1) || return 1
    assert_eq "helios v1.0.0" "$output"
    teardown_test_env
}

test_version_flags() {
    setup_test_env
    local flag output
    for flag in --version -V; do
        output=$("$HELIOS_BIN" "$flag" 2>&1) || return 1
        assert_eq "helios v1.0.0" "$output"
    done
    teardown_test_env
}

test_help() {
    setup_test_env
    local output
    output=$("$HELIOS_BIN" help 2>&1) || return 1
    assert_contains "$output" "USAGE:"
    assert_contains "$output" "WRAPPER FLAGS:"
    assert_contains "$output" "SUBCOMMANDS:"
    teardown_test_env
}

test_help_flags() {
    setup_test_env
    local flag output
    for flag in --help -h; do
        output=$("$HELIOS_BIN" "$flag" 2>&1) || return 1
        assert_contains "$output" "USAGE:"
    done
    teardown_test_env
}

# Wrapper mode & execution

test_wrapper_basic() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local output
    output=$("$HELIOS_BIN" --auto --full --dry-run -- echo "test game" 2>&1) || return 1
    assert_contains "$output" "DRY-RUN"
    assert_contains "$output" "VKD3D_CONFIG=dxr,dxr11"
    assert_contains "$output" "PROTON_ENABLE_NVAPI=1"
    assert_contains "$output" "PROTON_NO_FSYNC=0"
    assert_contains "$output" "echo"
    assert_contains "$output" "test\\ game"
    teardown_test_env
}

test_wrapper_no_separator() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local output
    output=$("$HELIOS_BIN" --auto --dry-run echo "test game" 2>&1) || return 1
    assert_contains "$output" "echo"
    assert_contains "$output" "test\\ game"
    teardown_test_env
}

test_wrapper_preserves_internal_dashdash() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local output
    output=$("$HELIOS_BIN" --auto --dry-run -- reaper arg1 -- game_arg1 game_arg2 2>&1) || return 1
    assert_contains "$output" "reaper arg1 -- game_arg1 game_arg2"
    teardown_test_env
}

test_wrapper_direct_flags_auto_no_rt() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local output
    output=$("$HELIOS_BIN" --auto --no-rt --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "PROTON_ENABLE_NVAPI=1"
    assert_not_contains "$output" "VKD3D_CONFIG=dxr"
    assert_contains "$output" "DXVK_ASYNC=1"
    teardown_test_env
}

test_wrapper_profile_flag() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local output
    output=$("$HELIOS_BIN" --profile=auto,-rt --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "PROTON_ENABLE_NVAPI=1"
    assert_not_contains "$output" "VKD3D_CONFIG=dxr"
    assert_contains "$output" "DXVK_ASYNC=1"
    teardown_test_env
}

test_wrapper_unknown_flag_errors() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local output
    output=$("$HELIOS_BIN" --unknown-flag --dry-run -- echo test 2>&1) && return 1
    assert_contains "$output" "Unknown flag"
    teardown_test_env
}

test_wrapper_missing_command_errors() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local output
    output=$("$HELIOS_BIN" --auto 2>&1) && return 1
    assert_contains "$output" "No game command"
    teardown_test_env
}

test_wrapper_verbose_output() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local output
    output=$("$HELIOS_BIN" --auto --verbose --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "Resolved profiles"
    assert_contains "$output" "GPU tier"
    assert_contains "$output" "Expanded base profiles"
    assert_contains "$output" "Environment variables"
    teardown_test_env
}

test_profile_vars_separate_env_args() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local output
    output=$("$HELIOS_BIN" --rt -- sh -c 'printf "VKD3D=%s|HIDE=%s\n" "$VKD3D_CONFIG" "$PROTON_HIDE_NVIDIA_GPU"' 2>&1) || return 1
    assert_eq "VKD3D=dxr,dxr11|HIDE=0" "$output"
    teardown_test_env
}

test_custom_profile_multiple_vars() {
    setup_test_env
    local config_file="$XDG_CONFIG_HOME/helios/helios.conf"
    mkdir -p "$(dirname "$config_file")"
    cat > "$config_file" <<'EOF'
HELIOS_PROFILE_mycustom="FOO_TEST=alpha BAR_TEST=beta"
EOF
    local output
    output=$("$HELIOS_BIN" --profile=mycustom -- sh -c 'printf "%s:%s\n" "$FOO_TEST" "$BAR_TEST"' 2>&1) || return 1
    assert_eq "alpha:beta" "$output"
    teardown_test_env
}

# GPU tier detection

test_gpu_tier_blackwell() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 5090"
    local output
    output=$("$HELIOS_BIN" --auto --verbose --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "blackwell"
    teardown_test_env
}

test_gpu_tier_ada() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local output
    output=$("$HELIOS_BIN" --auto --verbose --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "ada"
    teardown_test_env
}

test_gpu_tier_ampere() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 3070"
    local output
    output=$("$HELIOS_BIN" --auto --verbose --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "ampere"
    teardown_test_env
}

test_gpu_tier_turing() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 2060"
    local output
    output=$("$HELIOS_BIN" --auto --verbose --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "turing"
    teardown_test_env
}

test_gpu_tier_pre_rtx() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce GTX 1080 Ti"
    local output
    output=$("$HELIOS_BIN" --auto --verbose --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "pre_rtx"
    assert_contains "$output" "DXVK_ASYNC=1"
    assert_not_contains "$output" "PROTON_ENABLE_NVAPI"
    assert_not_contains "$output" "VKD3D_CONFIG"
    teardown_test_env
}

test_gpu_tier_none() {
    setup_test_env
    remove_mock_nvidia_smi
    local output
    output=$("$HELIOS_BIN" --auto --verbose --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "none"
    assert_not_contains "$output" "NVAPI"
    assert_not_contains "$output" "VKD3D_CONFIG"
    assert_not_contains "$output" "DXVK_ASYNC"
    teardown_test_env
}

test_gpu_tier_generic_rtx() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA RTX A6000"
    local output
    output=$("$HELIOS_BIN" --auto --verbose --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "rtx_generic"
    teardown_test_env
}

# Profile algebra & anticheat filter

test_algebra_ultra_minus_latency_rt() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local output
    output=$("$HELIOS_BIN" --profile=ultra,-latency,-rt --verbose --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "PROTON_ENABLE_NVAPI=1"
    assert_not_contains "$output" "VKD3D_CONFIG=dxr"
    assert_not_contains "$output" "__GL_MaxFramesAllowed=1"
    teardown_test_env
}

test_algebra_unknown_token_warns() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local output
    output=$("$HELIOS_BIN" --profile=auto,invalid_token --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "Unknown profile token"
    assert_contains "$output" "invalid_token"
    teardown_test_env
}

test_anticheat_filters_meta_profiles() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    export SteamAppId=730
    local output
    output=$("$HELIOS_BIN" --ultra --verbose --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "Competitive game detected"
    assert_not_contains "$output" "VKD3D_CONFIG=dxr"
    assert_not_contains "$output" "PROTON_ENABLE_NVAPI"
    assert_not_contains "$output" "DXVK_GPLASYNC"
    assert_contains "$output" "DXVK_ASYNC=1"
    assert_contains "$output" "PROTON_NO_FSYNC=0"
    teardown_test_env
}

test_unsafe_flag_bypasses_anticheat() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    export SteamAppId=730
    local output
    output=$("$HELIOS_BIN" --unsafe --ultra --dry-run -- echo test 2>&1) || return 1
    assert_not_contains "$output" "Competitive game detected"
    assert_contains "$output" "VKD3D_CONFIG=dxr,dxr11"
    assert_contains "$output" "PROTON_ENABLE_NVAPI=1"
    teardown_test_env
}

# Config parser security

test_config_rejects_command_substitution() {
    setup_test_env
    local config_file="$XDG_CONFIG_HOME/helios/helios.conf"
    mkdir -p "$(dirname "$config_file")"
    cat > "$config_file" <<'EOF'
HELIOS_DEFAULT_PROFILES="$(touch /tmp/hacked)"
EOF
    local output
    output=$("$HELIOS_BIN" --auto --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "rejected value with shell metacharacters"
    teardown_test_env
}

test_config_rejects_backticks() {
    setup_test_env
    local config_file="$XDG_CONFIG_HOME/helios/helios.conf"
    mkdir -p "$(dirname "$config_file")"
    cat > "$config_file" <<'EOF'
HELIOS_DEFAULT_PROFILES="`touch /tmp/hacked`"
EOF
    local output
    output=$("$HELIOS_BIN" --auto --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "rejected value with shell metacharacters"
    teardown_test_env
}

test_config_rejects_semicolon_and_pipe() {
    setup_test_env
    local config_file="$XDG_CONFIG_HOME/helios/helios.conf"
    mkdir -p "$(dirname "$config_file")"
    cat > "$config_file" <<'EOF'
HELIOS_DEFAULT_PROFILES="auto; rm -rf /"
HELIOS_APP_123="auto | cat /etc/passwd"
EOF
    local output
    output=$("$HELIOS_BIN" --auto --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "rejected value with shell metacharacters"
    teardown_test_env
}

test_config_ignores_malformed_lines() {
    setup_test_env
    local config_file="$XDG_CONFIG_HOME/helios/helios.conf"
    mkdir -p "$(dirname "$config_file")"
    cat > "$config_file" <<'EOF'
INVALID LINE
HELIOS_DEFAULT_PROFILES="perf"
=NO_KEY
KEY_NO_EQUALS
EOF
    local output
    output=$("$HELIOS_BIN" --verbose --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "DXVK_ASYNC=1"
    teardown_test_env
}

# Priority order & symlinks

test_priority_cli_over_alias() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local bin_dir
    bin_dir=$(dirname "$HELIOS_BIN")
    ln -sf "$HELIOS_BIN" "$bin_dir/helios-testalias"

    local config_file="$XDG_CONFIG_HOME/helios/helios.conf"
    mkdir -p "$(dirname "$config_file")"
    cat > "$config_file" <<'EOF'
HELIOS_ALIAS_testalias="perf"
EOF

    local output
    output=$("$bin_dir/helios-testalias" --auto --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "PROTON_ENABLE_NVAPI=1"
    assert_contains "$output" "VKD3D_CONFIG=dxr,dxr11"
    teardown_test_env
}

test_hx_and_alias_symlinks() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local bin_dir
    bin_dir=$(dirname "$HELIOS_BIN")
    ln -sf "$HELIOS_BIN" "$bin_dir/hx-fast"
    ln -sf "$HELIOS_BIN" "$bin_dir/helios_alias_fast"

    local config_file="$XDG_CONFIG_HOME/helios/helios.conf"
    mkdir -p "$(dirname "$config_file")"
    cat > "$config_file" <<'EOF'
HELIOS_ALIAS_fast="latency"
EOF

    local out1 out2
    out1=$("$bin_dir/hx-fast" --dry-run -- echo test 2>&1) || return 1
    out2=$("$bin_dir/helios_alias_fast" --dry-run -- echo test 2>&1) || return 1
    assert_contains "$out1" "__GL_MaxFramesAllowed=1"
    assert_contains "$out2" "__GL_MaxFramesAllowed=1"
    teardown_test_env
}

test_priority_alias_over_appid() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local bin_dir
    bin_dir=$(dirname "$HELIOS_BIN")
    ln -sf "$HELIOS_BIN" "$bin_dir/helios-aliaswin"

    local config_file="$XDG_CONFIG_HOME/helios/helios.conf"
    mkdir -p "$(dirname "$config_file")"
    cat > "$config_file" <<'EOF'
HELIOS_ALIAS_aliaswin="dlss,perf"
HELIOS_APP_12345="rt,perf"
EOF

    export SteamAppId=12345
    local output
    output=$("$bin_dir/helios-aliaswin" --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "PROTON_ENABLE_NVAPI=1"
    assert_not_contains "$output" "VKD3D_CONFIG=dxr"
    teardown_test_env
}

test_priority_appid_over_default() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local config_file="$XDG_CONFIG_HOME/helios/helios.conf"
    mkdir -p "$(dirname "$config_file")"
    cat > "$config_file" <<'EOF'
HELIOS_DEFAULT_PROFILES="perf"
HELIOS_APP_12345="dlss,rt"
EOF

    export SteamAppId=12345
    local output
    output=$("$HELIOS_BIN" --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "PROTON_ENABLE_NVAPI=1"
    assert_contains "$output" "VKD3D_CONFIG=dxr,dxr11"
    assert_not_contains "$output" "DXVK_ASYNC=1"
    teardown_test_env
}

test_priority_default_over_auto() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local config_file="$XDG_CONFIG_HOME/helios/helios.conf"
    mkdir -p "$(dirname "$config_file")"
    cat > "$config_file" <<'EOF'
HELIOS_DEFAULT_PROFILES="perf,latency"
EOF

    local output
    output=$("$HELIOS_BIN" --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "DXVK_ASYNC=1"
    assert_contains "$output" "__GL_MaxFramesAllowed=1"
    assert_not_contains "$output" "PROTON_ENABLE_NVAPI"
    teardown_test_env
}

test_priority_steam_compat_data_path() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local config_file="$XDG_CONFIG_HOME/helios/helios.conf"
    mkdir -p "$(dirname "$config_file")"
    cat > "$config_file" <<'EOF'
HELIOS_APP_999999="latency"
EOF

    export STEAM_COMPAT_DATA_PATH="/home/user/.steam/steam/steamapps/compatdata/999999"
    local output
    output=$("$HELIOS_BIN" --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "__GL_MaxFramesAllowed=1"
    teardown_test_env
}

# Set/Unset/Games/Alias/Link

test_set_unset_games() {
    setup_test_env
    local config_file="$XDG_CONFIG_HOME/helios/helios.conf"
    mkdir -p "$(dirname "$config_file")"

    "$HELIOS_BIN" set 12345 "ultra" 2>&1 || return 1
    grep -q 'HELIOS_APP_12345="ultra"' "$config_file" || return 1

    local output
    output=$("$HELIOS_BIN" games 2>&1) || return 1
    assert_contains "$output" "12345"
    assert_contains "$output" "ultra"

    "$HELIOS_BIN" unset 12345 2>&1 || return 1
    ! grep -q 'HELIOS_APP_12345' "$config_file" || return 1

    output=$("$HELIOS_BIN" games 2>&1) || return 1
    assert_contains "$output" "No game overrides"
    teardown_test_env
}

test_alias_set_list_unset() {
    setup_test_env
    local config_file="$XDG_CONFIG_HOME/helios/helios.conf"
    mkdir -p "$(dirname "$config_file")"

    "$HELIOS_BIN" alias set my-alias "dlss,perf" 2>&1 || return 1
    grep -q 'HELIOS_ALIAS_my-alias="dlss,perf"' "$config_file" || return 1

    local output
    output=$("$HELIOS_BIN" alias list 2>&1) || return 1
    assert_contains "$output" "my-alias"
    assert_contains "$output" "dlss,perf"

    "$HELIOS_BIN" alias unset my-alias 2>&1 || return 1
    ! grep -q 'HELIOS_ALIAS_my-alias' "$config_file" || return 1
    teardown_test_env
}

test_alias_name_validation() {
    setup_test_env
    local output
    output=$("$HELIOS_BIN" alias set "invalid name" "perf" 2>&1) && return 1
    assert_contains "$output" "must match"
    teardown_test_env
}

test_link_unlink_links() {
    setup_test_env
    local bin_dir
    bin_dir=$(dirname "$HELIOS_BIN")
    local link_path="$bin_dir/helios-mylink"

    "$HELIOS_BIN" link mylink "perf,latency" 2>&1 || return 1
    [[ -L "$link_path" ]] || return 1
    [[ "$(readlink "$link_path")" == "$HELIOS_BIN" ]] || return 1

    local list_out
    list_out=$("$HELIOS_BIN" links 2>&1) || return 1
    assert_contains "$list_out" "mylink"

    local config_file="$XDG_CONFIG_HOME/helios/helios.conf"
    grep -q 'HELIOS_ALIAS_mylink="perf,latency"' "$config_file" || return 1

    "$HELIOS_BIN" unlink mylink --purge 2>&1 || return 1
    [[ ! -L "$link_path" ]] || return 1
    ! grep -q 'HELIOS_ALIAS_mylink' "$config_file" || return 1

    # Refuse overwrite of non-symlink regular file
    echo "regular" > "$bin_dir/helios-existing"
    local err_out
    err_out=$("$HELIOS_BIN" link existing 2>&1) && return 1
    assert_contains "$err_out" "not a symlink"
    teardown_test_env
}

# Diff, Export, Import

test_diff_shows_differences() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local output
    output=$("$HELIOS_BIN" diff auto ultra 2>&1) || return 1
    assert_contains "$output" "Diff:"
    assert_contains "$output" "PROTON_NO_FSYNC"
    teardown_test_env
}

test_export_and_import() {
    setup_test_env
    local config_file="$XDG_CONFIG_HOME/helios/helios.conf"
    mkdir -p "$(dirname "$config_file")"
    cat > "$config_file" <<'EOF'
HELIOS_DEFAULT_PROFILES="auto"
HELIOS_APP_111="old"
EOF

    local out
    out=$("$HELIOS_BIN" export 2>&1) || return 1
    assert_contains "$out" 'HELIOS_APP_111="old"'

    local import_file="$TEST_ROOT/import.conf"
    cat > "$import_file" <<'EOF'
HELIOS_APP_111="updated"
HELIOS_APP_222="new"
INVALID_KEY="value"
HELIOS_APP_123="bad;command"
EOF

    "$HELIOS_BIN" import "$import_file" --merge 2>&1 || return 1
    grep -q 'HELIOS_DEFAULT_PROFILES="auto"' "$config_file" || return 1
    grep -q 'HELIOS_APP_111="updated"' "$config_file" || return 1
    grep -q 'HELIOS_APP_222="new"' "$config_file" || return 1
    ! grep -q 'HELIOS_APP_111="old"' "$config_file" || return 1
    ! grep -q 'INVALID_KEY' "$config_file" || return 1
    ! grep -q 'HELIOS_APP_123' "$config_file" || return 1

    "$HELIOS_BIN" import "$import_file" --replace 2>&1 || return 1
    ! grep -q 'HELIOS_DEFAULT_PROFILES' "$config_file" || return 1
    grep -q 'HELIOS_APP_222="new"' "$config_file" || return 1
    teardown_test_env
}

# DLL management

test_dll_list_backup_swap_restore() {
    setup_test_env
    create_mock_sha256sum

    local dll_dir="$TEST_ROOT/dlls"
    mkdir -p "$dll_dir/subdir"
    printf 'MZoriginal' > "$dll_dir/nvngx_dlss.dll"
    printf 'MZnew_pe_dll' > "$TEST_ROOT/new.dll"
    printf 'NOT_PE' > "$TEST_ROOT/bad.dll"

    local list_out
    list_out=$("$HELIOS_BIN" dll list "$dll_dir" 2>&1) || return 1
    assert_contains "$list_out" "nvngx_dlss.dll"
    assert_contains "$list_out" "abcdef1234567890"

    local bad_out
    bad_out=$("$HELIOS_BIN" dll swap "$dll_dir/nvngx_dlss.dll" "$TEST_ROOT/bad.dll" 2>&1) && return 1
    assert_contains "$bad_out" "missing MZ magic"

    "$HELIOS_BIN" dll swap "$dll_dir/nvngx_dlss.dll" "$TEST_ROOT/new.dll" 2>&1 || return 1
    [[ "$(cat "$dll_dir/nvngx_dlss.dll")" == "MZnew_pe_dll" ]] || return 1

    "$HELIOS_BIN" dll restore "$dll_dir/nvngx_dlss.dll" 2>&1 || return 1
    [[ "$(cat "$dll_dir/nvngx_dlss.dll")" == "MZoriginal" ]] || return 1
    teardown_test_env
}

# Autotune

test_autotune_cases() {
    setup_test_env
    local steam_base="$HOME/.local/share/Steam"
    create_fake_steam_lib "$steam_base" 12345 "GameDir" "nvngx_dlss.dll" "d3d12.dll"

    local output
    output=$("$HELIOS_BIN" autotune 12345 --yes 2>&1) || return 1
    assert_contains "$output" "DLSS=true"
    assert_contains "$output" "DX12=true"
    grep -q 'HELIOS_APP_12345="dlss,rt,perf"' "$XDG_CONFIG_HOME/helios/helios.conf" || return 1

    local dlss_only="$TEST_ROOT/dlss_only"
    mkdir -p "$dlss_only"
    touch "$dlss_only/nvngx_dlss.dll"
    output=$("$HELIOS_BIN" autotune 999 --dir "$dlss_only" 2>&1) || return 1
    assert_contains "$output" "Recommendation: dlss,perf"

    local dx12_only="$TEST_ROOT/dx12_only"
    mkdir -p "$dx12_only"
    touch "$dx12_only/d3d12.dll"
    output=$("$HELIOS_BIN" autotune 999 --dir "$dx12_only" 2>&1) || return 1
    assert_contains "$output" "Recommendation: perf"
    teardown_test_env
}

# Fail-open guarantees & run subcommand

test_failopen_cases() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local bin_dir
    bin_dir=$(dirname "$HELIOS_BIN")
    ln -sf "$HELIOS_BIN" "$bin_dir/helios-missingalias"

    local out
    out=$("$bin_dir/helios-missingalias" --dry-run -- echo test 2>&1) || return 1
    assert_contains "$out" "not found in config"
    assert_contains "$out" "PROTON_ENABLE_NVAPI=1"

    out=$("$HELIOS_BIN" --profile=invalid_token --dry-run -- echo test 2>&1) || return 1
    assert_contains "$out" "Unknown profile token"

    out=$("$HELIOS_BIN" run --auto --dry-run -- echo test 2>&1) || return 1
    assert_contains "$out" "PROTON_ENABLE_NVAPI=1"

    # Verify child process keeps default space/tab/newline IFS
    out=$("$HELIOS_BIN" --auto -- sh -c 'printf "%s" "$IFS" | od -An -tx1 | tr -d " \n"' 2>&1) || return 1
    assert_eq "20090a" "$out"

    teardown_test_env
}

test_global_flags_before_subcommand() {
    setup_test_env
    create_mock_nvidia_smi "NVIDIA GeForce RTX 4080"
    local custom_config="$TEST_ROOT/custom.conf"
    echo 'HELIOS_DEFAULT_PROFILES="perf,latency"' > "$custom_config"

    local output
    output=$("$HELIOS_BIN" --verbose scan 2>&1) || return 1
    assert_contains "$output" "helios v1.0.0"

    output=$("$HELIOS_BIN" --config "$custom_config" --dry-run -- echo test 2>&1) || return 1
    assert_contains "$output" "DXVK_ASYNC=1"
    assert_contains "$output" "__GL_MaxFramesAllowed=1"
    assert_not_contains "$output" "PROTON_ENABLE_NVAPI"
    teardown_test_env
}

main() {
    echo "Helios Test Suite"
    echo

    run_test "Syntax check (bash -n)" test_syntax_check
    run_test "Subcommand: scan" test_scan
    run_test "Subcommand: doctor alias" test_doctor_alias
    run_test "Subcommand: modes" test_modes
    run_test "Subcommand: profiles alias" test_profiles_alias
    run_test "Subcommand: version" test_version
    run_test "Subcommand: --version / -V" test_version_flags
    run_test "Subcommand: help" test_help
    run_test "Subcommand: --help / -h" test_help_flags
    run_test "Wrapper: basic with -- separator" test_wrapper_basic
    run_test "Wrapper: no separator" test_wrapper_no_separator
    run_test "Wrapper: preserves internal --" test_wrapper_preserves_internal_dashdash
    run_test "Wrapper: --auto --no-rt" test_wrapper_direct_flags_auto_no_rt
    run_test "Wrapper: --profile=auto,-rt" test_wrapper_profile_flag
    run_test "Wrapper: unknown flag errors" test_wrapper_unknown_flag_errors
    run_test "Wrapper: missing command errors" test_wrapper_missing_command_errors
    run_test "Wrapper: verbose output" test_wrapper_verbose_output
    run_test "Exec: env vars passed as separate args" test_profile_vars_separate_env_args
    run_test "Exec: custom profile multiple vars" test_custom_profile_multiple_vars
    run_test "GPU: RTX 5090 -> blackwell" test_gpu_tier_blackwell
    run_test "GPU: RTX 4080 -> ada" test_gpu_tier_ada
    run_test "GPU: RTX 3070 -> ampere" test_gpu_tier_ampere
    run_test "GPU: RTX 2060 -> turing" test_gpu_tier_turing
    run_test "GPU: GTX 1080 Ti -> pre_rtx" test_gpu_tier_pre_rtx
    run_test "GPU: no nvidia-smi -> none" test_gpu_tier_none
    run_test "GPU: Generic RTX -> rtx_generic" test_gpu_tier_generic_rtx
    run_test "Algebra: ultra,-latency,-rt" test_algebra_ultra_minus_latency_rt
    run_test "Algebra: unknown token warns" test_algebra_unknown_token_warns
    run_test "Anticheat: filters expanded meta-profiles" test_anticheat_filters_meta_profiles
    run_test "Anticheat: --unsafe bypasses filter" test_unsafe_flag_bypasses_anticheat
    run_test "Config: rejects command substitution" test_config_rejects_command_substitution
    run_test "Config: rejects backticks" test_config_rejects_backticks
    run_test "Config: rejects semicolon and pipe" test_config_rejects_semicolon_and_pipe
    run_test "Config: ignores malformed lines" test_config_ignores_malformed_lines
    run_test "Priority: CLI > alias" test_priority_cli_over_alias
    run_test "Priority: hx-* and helios_alias_* symlinks" test_hx_and_alias_symlinks
    run_test "Priority: alias > AppID" test_priority_alias_over_appid
    run_test "Priority: AppID > default" test_priority_appid_over_default
    run_test "Priority: default > auto" test_priority_default_over_auto
    run_test "Priority: STEAM_COMPAT_DATA_PATH" test_priority_steam_compat_data_path
    run_test "Commands: set/unset/games" test_set_unset_games
    run_test "Commands: alias set/list/unset" test_alias_set_list_unset
    run_test "Commands: alias name validation" test_alias_name_validation
    run_test "Commands: link/links/unlink" test_link_unlink_links
    run_test "Commands: diff" test_diff_shows_differences
    run_test "Commands: export and import" test_export_and_import
    run_test "Commands: dll list/swap/restore" test_dll_list_backup_swap_restore
    run_test "Commands: autotune" test_autotune_cases
    run_test "Fail-open, run subcommand, IFS isolation" test_failopen_cases
    run_test "Global flags before subcommand" test_global_flags_before_subcommand

    echo
    echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed, $TESTS_RUN total"
    [[ $TESTS_FAILED -eq 0 ]] || exit 1
}

main "$@"
