#!/bin/bash

set -u

SCRIPT_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

WORK_ROOT="${GCT_WORK_ROOT:-$HOME/gct_workspace}"
REPO_ROOT="$WORK_ROOT/repos"
LOG_ROOT="$WORK_ROOT/logs"
TMP_ROOT="$WORK_ROOT/tmp"
RUNTIME_ROOT="$WORK_ROOT/runtime"
TASK_DIR="$RUNTIME_ROOT/tasks"
TASK_HISTORY_DIR="$RUNTIME_ROOT/history"
TASK_CONFIG_DIR="$RUNTIME_ROOT/configs"
AUTO_REFRESH_DEFAULT="${GCT_AUTO_REFRESH_DEFAULT:-1}"
AUTO_REFRESH_INTERVAL="${GCT_AUTO_REFRESH_INTERVAL:-1}"

OPENWRT_REPOS=(
    "GDM|linuxos master|linuxos|master|https://release.gctsemi.com/linuxos"
    "SBL|7275X SBL|7275X_sbl||https://release.gctsemi.com/sbl/7275x"
    "UBOOT|7275X U-Boot|7275X_uboot||https://release.gctsemi.com/u-boot/7275x"
)

REPO_HASH_TARGETS=(
    "linuxos master|linuxos|master"
    "7275X SBL|7275X_sbl|"
    "7275X U-Boot|7275X_uboot|"
)

REPOSITORY_CLONE_TARGETS=(
    "linuxos v1.00|linuxos|v1.00|https://release.gctsemi.com/linuxos"
    "linuxos master|linuxos|master|https://release.gctsemi.com/linuxos"
    "openwrt v1.00|openwrt|v1.00|https://release.gctsemi.com/openwrt"
    "openwrt master|openwrt|master|https://release.gctsemi.com/openwrt"
    "uc1310|uc1310||https://jamesahn@vcs.gctsemi.com/lte/fw/linux/uc1310"
    "Zephyros|Zephyros||https://jamesahn@vcs.gctsemi.com/OS/Zephyros"
    "uTKernel|uTKernel||https://jamesahn@vcs.gctsemi.com/OS/uTKernel"
    "7275X U-Boot|7275X_uboot||https://eng05@release.gctsemi.com/u-boot/7275x"
    "7275X SBL|7275X_sbl||https://eng05@release.gctsemi.com/sbl/7275x"
    "Zephyr v2.3|zephyr-v2.3||https://jamesahn@vcs.gctsemi.com/OS/zephyr-v2.3"
)

RELEASE_NOTE_COMMON_AP_REPOS=(
    "linuxos master|linuxos|master"
    "uc1310|uc1310|"
)

RELEASE_NOTE_CP_REPOS=(
    "Zephyros|Zephyros|"
)

init_workspace() {
    mkdir -p "$REPO_ROOT" "$LOG_ROOT" "$TMP_ROOT" "$TASK_DIR" "$TASK_HISTORY_DIR" "$TASK_CONFIG_DIR"
}

format_duration() {
    local total_seconds="${1:-0}"
    local hours=$((total_seconds / 3600))
    local minutes=$(((total_seconds % 3600) / 60))
    local seconds=$((total_seconds % 60))
    printf "%02d:%02d:%02d" "$hours" "$minutes" "$seconds"
}

pause_enter() {
    read -r -p "Press Enter to continue... " _
}

clear_screen() {
    if command -v clear >/dev/null 2>&1; then
        clear
    fi
}

require_commands() {
    local missing=0
    local cmd
    for cmd in "$@"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "❌ Required command not found: $cmd"
            missing=1
        fi
    done
    if [ "$missing" -ne 0 ]; then
        exit 1
    fi
}

write_env_pairs() {
    local file=$1
    shift
    : > "$file"
    while [ "$#" -gt 0 ]; do
        local key=$1
        local value=$2
        shift 2
        printf '%s=%q\n' "$key" "$value" >> "$file"
    done
}

set_kv_in_file() {
    local file=$1
    local key=$2
    local value=$3
    local tmp
    tmp="$(mktemp)"
    if [ -f "$file" ]; then
        grep -v "^${key}=" "$file" > "$tmp" || true
    fi
    printf '%s=%q\n' "$key" "$value" >> "$tmp"
    mv "$tmp" "$file"
}

load_env_file() {
    local file=$1
    if [ -f "$file" ]; then
        # shellcheck disable=SC1090
        . "$file"
    fi
}

repo_dir_for() {
    local repo_key=$1
    local branch="${2:-}"
    case "$repo_key" in
        openwrt)
            printf '%s/openwrt/%s\n' "$REPO_ROOT" "$branch"
            ;;
        linuxos)
            printf '%s/linuxos/%s\n' "$REPO_ROOT" "$branch"
            ;;
        7275X_sbl|7275X_uboot|uc1310|Zephyros)
            printf '%s/%s\n' "$REPO_ROOT" "$repo_key"
            ;;
        *)
            printf '%s/%s\n' "$REPO_ROOT" "$repo_key"
            ;;
    esac
}

ensure_repo_parent() {
    local repo_dir=$1
    mkdir -p "$(dirname "$repo_dir")"
}

ensure_repo_paths_available() {
    local target_repo
    for target_repo in "$@"; do
        [ -n "$target_repo" ] || continue
        local file
        for file in "$TASK_DIR"/*.task; do
            [ -e "$file" ] || continue
            unset STATUS REPO_DIR TASK_ID PROJECT JOB BRANCH RESERVED_REPO_DIRS
            load_env_file "$file"
            if [ -n "${TASK_ID:-}" ]; then
                load_env_file "$(task_config_path "$TASK_ID")"
            fi
            if [ "${STATUS:-}" = "RUNNING" ] && [ "${REPO_DIR:-}" = "$target_repo" ]; then
                echo "❌ 동일 repo 경로를 사용하는 작업이 이미 실행 중입니다."
                echo "   Repo    : $target_repo"
                echo "   Running : ${PROJECT:-unknown} / ${JOB:-unknown} / ${BRANCH:-default}"
                return 1
            fi
            if [ "${STATUS:-}" = "RUNNING" ] && [ -n "${RESERVED_REPO_DIRS:-}" ]; then
                case ":$RESERVED_REPO_DIRS:" in
                    *":$target_repo:"*)
                        echo "❌ 동일 repo 경로를 사용하는 작업이 이미 실행 중입니다."
                        echo "   Repo    : $target_repo"
                        echo "   Running : ${PROJECT:-unknown} / ${JOB:-unknown} / ${BRANCH:-default}"
                        return 1
                        ;;
                esac
            fi
        done
    done
    return 0
}

cleanup_stale_tasks() {
    init_workspace
    local file
    for file in "$TASK_DIR"/*.task; do
        [ -e "$file" ] || continue
        unset TASK_ID PROJECT JOB BRANCH STATUS CREATED_AT START_EPOCH END_EPOCH SESSION_NAME LOG_DIR REPO_DIR RUN_ID
        load_env_file "$file"
        if [ "${STATUS:-}" = "RUNNING" ] && [ -n "${SESSION_NAME:-}" ]; then
            if ! tmux has-session -t "$SESSION_NAME" >/dev/null 2>&1; then
                set_kv_in_file "$file" "STATUS" "STALE"
                set_kv_in_file "$file" "ENDED_AT" "$(date '+%Y-%m-%d %H:%M:%S')"
                set_kv_in_file "$file" "END_EPOCH" "$(date +%s)"
                mv "$file" "$TASK_HISTORY_DIR/$(basename "$file")"
            fi
        fi
    done
}

has_running_tasks() {
    cleanup_stale_tasks

    local file
    for file in "$TASK_DIR"/*.task; do
        [ -e "$file" ] || continue
        unset STATUS
        load_env_file "$file"
        if [ "${STATUS:-}" = "RUNNING" ]; then
            return 0
        fi
    done

    return 1
}

render_running_tasks() {
    cleanup_stale_tasks
    echo "[Running Tasks]"
    local found=0
    local file
    for file in "$TASK_DIR"/*.task; do
        [ -e "$file" ] || continue
        unset TASK_ID PROJECT JOB BRANCH STATUS START_EPOCH CREATED_AT SESSION_NAME
        load_env_file "$file"
        [ "${STATUS:-}" = "RUNNING" ] || continue
        found=1
        local elapsed="--:--:--"
        local base_epoch="${START_EPOCH:-}"
        if [ -n "$base_epoch" ]; then
            elapsed="$(format_duration "$(( $(date +%s) - base_epoch ))")"
        fi
        printf ' - %s [%s] elapsed=%s start=%s\n' \
            "$(task_display_name "${PROJECT:-unknown}" "${JOB:-unknown}" "${BRANCH:-default}")" \
            "${STATUS:-unknown}" \
            "$elapsed" \
            "${STARTED_AT:-${CREATED_AT:-unknown}}"
    done
    if [ "$found" -eq 0 ]; then
        echo " - none"
    fi
}

render_recent_tasks() {
    echo "[Recent Tasks]"
    local files=()
    local file
    while IFS= read -r file; do
        files+=("$file")
    done < <(find "$TASK_HISTORY_DIR" -maxdepth 1 -type f -name '*.task' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n 5 | awk '{print $2}')

    if [ "${#files[@]}" -eq 0 ]; then
        echo " - none"
        return
    fi

    for file in "${files[@]}"; do
        unset PROJECT JOB BRANCH STATUS START_EPOCH END_EPOCH STARTED_AT ENDED_AT CREATED_AT
        load_env_file "$file"
        local duration="--:--:--"
        if [ -n "${START_EPOCH:-}" ] && [ -n "${END_EPOCH:-}" ]; then
            duration="$(format_duration "$(( END_EPOCH - START_EPOCH ))")"
        fi
        printf ' - %s [%s] duration=%s start=%s end=%s\n' \
            "$(task_display_name "${PROJECT:-unknown}" "${JOB:-unknown}" "${BRANCH:-default}")" \
            "${STATUS:-unknown}" \
            "$duration" \
            "${STARTED_AT:-${CREATED_AT:-unknown}}" \
            "${ENDED_AT:-unknown}"
    done
}

task_display_name() {
    local project=$1
    local job=$2
    local branch=$3

    case "${project}:${job}:${branch}" in
        openwrt:official_release:multi)
            printf 'OpenWRT official release'
            ;;
        openwrt:dirty_build:master)
            printf 'OpenWRT master build'
            ;;
        openwrt:dirty_build:v1.00)
            printf 'OpenWRT v1.00 build'
            ;;
        openwrt:dirty_clone:master)
            printf 'OpenWRT master clone'
            ;;
        openwrt:dirty_clone:v1.00)
            printf 'OpenWRT v1.00 clone'
            ;;
        linuxos:dirty_build:master)
            printf 'LinuxOS master build'
            ;;
        zephyros:gdm7275x_nsa_build:default)
            printf 'Zephyros GDM7275x_nsa build'
            ;;
        zephyros:gdm7275x_nsa_pkgver_build:default)
            printf 'Zephyros GDM7275x_nsa build with PKGVER'
            ;;
        release_note:generate:default)
            printf 'Release Note generate'
            ;;
        utility:repo_hash_check:default)
            printf 'Repository hash check'
            ;;
        utility:repo_clone:linuxos_v1_00*)
            printf 'Repository clone - linuxos v1.00'
            ;;
        utility:repo_clone:linuxos_master*)
            printf 'Repository clone - linuxos master'
            ;;
        utility:repo_clone:openwrt_v1_00*)
            printf 'Repository clone - openwrt v1.00'
            ;;
        utility:repo_clone:openwrt_master*)
            printf 'Repository clone - openwrt master'
            ;;
        utility:repo_clone:uc1310*)
            printf 'Repository clone - uc1310'
            ;;
        utility:repo_clone:zephyros*)
            printf 'Repository clone - Zephyros'
            ;;
        utility:repo_clone:utkernel*)
            printf 'Repository clone - uTKernel'
            ;;
        utility:repo_clone:7275x_uboot*)
            printf 'Repository clone - 7275X U-Boot'
            ;;
        utility:repo_clone:7275x_sbl*)
            printf 'Repository clone - 7275X SBL'
            ;;
        utility:repo_clone:zephyr_v2_3*)
            printf 'Repository clone - Zephyr v2.3'
            ;;
        utility:repo_clone:*)
            case "$branch" in
                linuxos_v1_00)
                    printf 'Repository clone - linuxos v1.00'
                    ;;
                linuxos_master)
                    printf 'Repository clone - linuxos master'
                    ;;
                openwrt_v1_00)
                    printf 'Repository clone - openwrt v1.00'
                    ;;
                openwrt_master)
                    printf 'Repository clone - openwrt master'
                    ;;
                uc1310)
                    printf 'Repository clone - uc1310'
                    ;;
                zephyros)
                    printf 'Repository clone - Zephyros'
                    ;;
                utkernel)
                    printf 'Repository clone - uTKernel'
                    ;;
                7275x_uboot)
                    printf 'Repository clone - 7275X U-Boot'
                    ;;
                7275x_sbl)
                    printf 'Repository clone - 7275X SBL'
                    ;;
                zephyr_v2_3)
                    printf 'Repository clone - Zephyr v2.3'
                    ;;
                *)
                    printf 'Repository clone - %s' "$branch"
                    ;;
            esac
            ;;
        *)
            printf '%s / %s / %s' "$project" "$job" "$branch"
            ;;
    esac
}

task_slug_name() {
    local project=$1
    local job=$2
    local branch=$3

    case "${project}:${job}:${branch}" in
        openwrt:official_release:multi)
            printf 'openwrt_official_release'
            ;;
        openwrt:dirty_build:master)
            printf 'openwrt_master_build'
            ;;
        openwrt:dirty_build:v1.00)
            printf 'openwrt_v1_00_build'
            ;;
        openwrt:dirty_clone:master)
            printf 'openwrt_master_clone'
            ;;
        openwrt:dirty_clone:v1.00)
            printf 'openwrt_v1_00_clone'
            ;;
        linuxos:dirty_build:master)
            printf 'linuxos_master_build'
            ;;
        zephyros:gdm7275x_nsa_build:default)
            printf 'zephyros_gdm7275x_nsa_build'
            ;;
        zephyros:gdm7275x_nsa_pkgver_build:default)
            printf 'zephyros_gdm7275x_nsa_pkgver_build'
            ;;
        release_note:generate:default)
            printf 'release_note_generate'
            ;;
        utility:repo_hash_check:default)
            printf 'repository_hash_check'
            ;;
        utility:repo_clone:*)
            printf 'repository_clone_%s' "$branch"
            ;;
        *)
            printf '%s_%s_%s' "$project" "$job" "$branch" | tr ' /:' '_'
            ;;
    esac
}

print_main_header() {
    clear_screen
    echo "=========================================="
    echo " GCT Build Manager"
    echo "=========================================="
    echo "Workspace : $WORK_ROOT"
    echo
    render_running_tasks
    echo
    render_recent_tasks
    echo
}

prompt_menu_choice() {
    local prompt=$1
    local choice
    read -r -p "$prompt" choice
    printf '%s' "$choice"
}

prompt_dashboard_choice() {
    local prompt=$1
    local choice=""

    if [ "${AUTO_REFRESH_DEFAULT:-1}" = "1" ] && has_running_tasks; then
        if read -r -t "${AUTO_REFRESH_INTERVAL:-1}" -p "$prompt" choice; then
            printf '%s' "$choice"
        else
            printf '__REFRESH__'
        fi
        return 0
    fi

    prompt_menu_choice "$prompt"
}

prompt_non_empty() {
    local prompt=$1
    local value=""
    while [ -z "$value" ]; do
        read -r -p "$prompt" value
    done
    printf '%s' "$value"
}

select_commit_user() {
    local user_sel
    while true; do
        echo "Select commit user"
        echo "1) Kai Han"
        echo "2) James Ahn"
        user_sel="$(prompt_menu_choice "Choose: ")"
        case "$user_sel" in
            1)
                COMMIT_USER_NAME="Kai Han"
                COMMIT_USER_EMAIL="kaihan@gctsemi.com"
                return 0
                ;;
            2)
                COMMIT_USER_NAME="James Ahn"
                COMMIT_USER_EMAIL="jamesahn@gctsemi.com"
                return 0
                ;;
            *)
                echo "❌ invalid selection"
                ;;
        esac
    done
}

task_file_path() {
    local task_id=$1
    printf '%s/%s.task\n' "$TASK_DIR" "$task_id"
}

task_history_path() {
    local task_id=$1
    printf '%s/%s.task\n' "$TASK_HISTORY_DIR" "$task_id"
}

task_config_path() {
    local task_id=$1
    printf '%s/%s.env\n' "$TASK_CONFIG_DIR" "$task_id"
}

ensure_no_repo_conflict() {
    local target_repo=$1
    ensure_repo_paths_available "$target_repo"
}

launch_task() {
    local project=$1
    local job=$2
    local branch=$3
    local repo_dir=$4
    shift 4

    init_workspace
    cleanup_stale_tasks
    require_commands tmux

    if [ -n "$repo_dir" ]; then
        ensure_no_repo_conflict "$repo_dir" || {
            pause_enter
            return 1
        }
    fi

    local timestamp run_id task_id session_name log_dir config_file task_file cmd task_name task_slug
    timestamp="$(date +%Y%m%d_%H%M%S)"
    run_id="$timestamp"
    task_name="$(task_display_name "$project" "$job" "$branch")"
    task_slug="$(task_slug_name "$project" "$job" "$branch")"
    task_id="${task_slug}_${timestamp}"
    session_name="gct_${task_slug}_${timestamp}"
    log_dir="$LOG_ROOT/$project/$task_slug/$run_id"
    config_file="$(task_config_path "$task_id")"
    task_file="$(task_file_path "$task_id")"

    mkdir -p "$log_dir"
    write_env_pairs "$task_file" \
        "TASK_ID" "$task_id" \
        "PROJECT" "$project" \
        "JOB" "$job" \
        "BRANCH" "$branch" \
        "STATUS" "PENDING" \
        "CREATED_AT" "$(date '+%Y-%m-%d %H:%M:%S')" \
        "CREATED_EPOCH" "$(date +%s)" \
        "SESSION_NAME" "$session_name" \
        "RUN_ID" "$run_id" \
        "LOG_DIR" "$log_dir" \
        "REPO_DIR" "$repo_dir"

    write_env_pairs "$config_file" "$@"

    printf -v cmd 'bash %q __run_task %q' "$SCRIPT_SELF" "$task_id"
    if ! tmux new-session -d -s "$session_name" "$cmd"; then
        echo "❌ tmux session 생성 실패"
        rm -f "$task_file" "$config_file"
        pause_enter
        return 1
    fi

    echo
    echo "✅ Task launched"
    echo "Task     : $task_name"
    echo "Task ID  : $task_id"
    echo "Session  : $session_name"
    echo "Repo Dir : $repo_dir"
    echo "Log Dir  : $log_dir"
    pause_enter
}

update_task_status() {
    local task_id=$1
    local status=$2
    local task_file
    task_file="$(task_file_path "$task_id")"
    set_kv_in_file "$task_file" "STATUS" "$status"
}

archive_task() {
    local task_id=$1
    local task_file history_file
    task_file="$(task_file_path "$task_id")"
    history_file="$(task_history_path "$task_id")"
    if [ -f "$task_file" ]; then
        mv "$task_file" "$history_file"
    fi
}

update_repo_for_log() {
    local dir=$1
    local branch=$2

    if [ -n "$branch" ]; then
        git -C "$dir" fetch origin "+refs/heads/$branch:refs/remotes/origin/$branch" >/dev/null 2>&1
    else
        git -C "$dir" pull --ff-only >/dev/null 2>&1
    fi
}

repo_ref_for_log() {
    local dir=$1
    local branch=$2
    if [ -n "$branch" ]; then
        printf 'origin/%s\n' "$branch"
    else
        git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null
    fi
}

write_release_note_repo_log() {
    local since=$1
    local now=$2
    local disp=$3
    local repo_key=$4
    local branch=$5
    local dir ref

    dir="$(repo_dir_for "$repo_key" "$branch")"
    if [ ! -d "$dir/.git" ]; then
        echo "WARN: git repo 아님 또는 폴더 없음: $dir" >&2
        return
    fi

    if ! update_repo_for_log "$dir" "$branch"; then
        echo "WARN: repo update 실패: $disp ($dir)" >&2
        return
    fi

    ref="$(repo_ref_for_log "$dir" "$branch")"
    if [ -z "$ref" ]; then
        echo "WARN: branch/ref 조회 실패: $disp ($dir)" >&2
        return
    fi

    echo
    echo "$disp"
    git -C "$dir" log "$ref" --since="$since" --until="$now" --reverse --pretty=format:'- %s'
    echo
}

collect_openwrt_repo_hashes() {
    local base_dir_log=$1
    local entry

    for entry in "${OPENWRT_REPOS[@]}"; do
        local key disp repo_key check_branch url repo_dir branch hash
        IFS='|' read -r key disp repo_key check_branch url <<< "$entry"
        repo_dir="$(repo_dir_for "$repo_key" "$check_branch")"

        echo "[$disp]"
        if [ ! -d "$repo_dir/.git" ]; then
            echo "❌ git repo 아님: $repo_dir"
            return 1
        fi

        if [ -n "$check_branch" ]; then
            branch="origin/$check_branch"
            git -C "$repo_dir" fetch origin "+refs/heads/$check_branch:refs/remotes/origin/$check_branch" > "$base_dir_log" 2>&1
            hash="$(git -C "$repo_dir" rev-parse "$branch" 2>/dev/null || true)"
        else
            branch="$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
            git -C "$repo_dir" pull --ff-only > "$base_dir_log" 2>&1
            hash="$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || true)"
        fi

        if [ -z "$hash" ]; then
            echo "❌ pull/hash 조회 실패: $disp"
            cat "$base_dir_log"
            return 1
        fi

        echo "  - Branch : $branch"
        echo "  - Hash   : $hash"
        echo

        case "$key" in
            GDM)
                GDM_REPO="$url"
                GDM_COMMIT="$hash"
                GDM_BRANCH="$branch"
                ;;
            SBL)
                SBL_REPO="$url"
                SBL_COMMIT="$hash"
                SBL_BRANCH="$branch"
                ;;
            UBOOT)
                UBOOT_REPO="$url"
                UBOOT_COMMIT="$hash"
                UBOOT_BRANCH="$branch"
                ;;
        esac
    done

    rm -f "$base_dir_log"
}

update_openwrt_manifest() {
    local manifest_file=$1
    local pkg_version=$2

    python3 - "$manifest_file" "$pkg_version" \
        "$GDM_REPO" "$GDM_COMMIT" \
        "$SBL_REPO" "$SBL_COMMIT" \
        "$UBOOT_REPO" "$UBOOT_COMMIT" <<'PY'
import re
import sys
from pathlib import Path

manifest = Path(sys.argv[1])
pkg_version = sys.argv[2]
gdm_repo = sys.argv[3]
gdm_commit = sys.argv[4]
sbl_repo = sys.argv[5]
sbl_commit = sys.argv[6]
uboot_repo = sys.argv[7]
uboot_commit = sys.argv[8]

text = manifest.read_text(encoding="utf-8")

patterns = {
    r'^GCT_PKG_VERSION:=.*$': f'GCT_PKG_VERSION:={pkg_version}',
    r'^GDM_REPO:=.*$': f'GDM_REPO:="{gdm_repo}"',
    r'^GDM_COMMIT:=.*$': f'GDM_COMMIT:="{gdm_commit}"',
    r'^SBL_REPO:=.*$': f'SBL_REPO:="{sbl_repo}"',
    r'^SBL_COMMIT:=.*$': f'SBL_COMMIT:="{sbl_commit}"',
    r'^UBOOT_REPO:=.*$': f'UBOOT_REPO:="{uboot_repo}"',
    r'^UBOOT_COMMIT:=.*$': f'UBOOT_COMMIT:="{uboot_commit}"',
}

needs_update = False

for pattern, replacement in patterns.items():
    match = re.search(pattern, text, flags=re.MULTILINE)
    if not match:
        print(f"ERROR: pattern not found -> {pattern}")
        sys.exit(2)
    if match.group(0) != replacement:
        needs_update = True

if not needs_update:
    sys.exit(10)

for pattern, replacement in patterns.items():
    text = re.sub(pattern, replacement, text, flags=re.MULTILINE)

manifest.write_text(text, encoding="utf-8")
PY
}

run_openwrt_expect_build() {
    local build_dir=$1
    local build_log=$2
    local label=$3
    local expect_script="$TASK_TMP_DIR/openwrt_${label}.exp"

    cat > "$expect_script" <<'EXP'
#!/usr/bin/expect -f
set timeout -1
log_user 1

set build_dir [lindex $argv 0]
set build_log [lindex $argv 1]
set build_label [lindex $argv 2]

spawn bash

expect -re {[$#] $}
send "cd -- \"$build_dir\"\r"

expect -re {[$#] $}
send "cd -- \"$build_dir\" && bash ./ext-toolchain.sh; printf '\\n__EXT_RC__:%s\\n' \$?\r"

set timeout 60
expect {
    -re {Select target system:} {}
    -re {default.*1} {}
    -re {Press[[:space:]]+Enter} {}
    -re {\[1\]} {}
    timeout {
        send_user "\n===== EXT-TOOLCHAIN PROMPT NOT FOUND =====\n"
        exit 1
    }
}

after 5000
send "\r"
set timeout -1

expect {
    -re {__EXT_RC__:0} {
        send_user "\n===== EXT-TOOLCHAIN SUCCESS =====\n"
    }
    -re {__EXT_RC__:[1-9][0-9]*} {
        send_user "\n===== EXT-TOOLCHAIN FAIL =====\n"
        exit 1
    }
    timeout {
        send_user "\n===== EXT-TOOLCHAIN TIMEOUT =====\n"
        exit 1
    }
}

expect -re {[$#] $}
send "cd -- \"$build_dir\" && set -o pipefail; make 2>&1 | tee -a \"$build_log\"; printf '\\n__BUILD_RC__:%s\\n' \$?\r"

expect {
    -re {__BUILD_RC__:0} {
        send_user "\n===== OPENWRT $build_label SUCCESS =====\n"
        exit 0
    }
    -re {__BUILD_RC__:[1-9][0-9]*} {
        send_user "\n===== OPENWRT $build_label FAIL =====\n"
        exit 1
    }
    timeout {
        send_user "\n===== OPENWRT $build_label TIMEOUT =====\n"
        exit 1
    }
}
EXP

    chmod +x "$expect_script"
    "$expect_script" "$build_dir" "$build_log" "$label"
}

run_zephyros_expect_build() {
    local repo_dir=$1
    local pkg_version=$2
    local build_log=$3
    local expect_script="$TASK_TMP_DIR/zephyros_build.exp"

    cat > "$expect_script" <<'EXP'
#!/usr/bin/expect -f
set timeout -1
log_user 1

set repo_dir [lindex $argv 0]
set pkgver [lindex $argv 1]
set build_log [lindex $argv 2]

spawn bash

expect -re {[$#] $}
send "cd -- \"$repo_dir\"\r"

expect -re {[$#] $}
if {$pkgver eq ""} {
    send "source ./build_config.sh; printf '\\n__CFG_RC__:%s\\n' \$?\r"
} else {
    send "source ./build_config.sh \"$pkgver\"; printf '\\n__CFG_RC__:%s\\n' \$?\r"
}

expect {
    -re {Select \[1-27\]>>} {
        send "7\r"
    }
    -re {__CFG_RC__:0} {}
    timeout {
        send_user "\n===== ZEPHYROS CONFIG PROMPT NOT FOUND =====\n"
        exit 1
    }
}

expect {
    -re {__CFG_RC__:0} {}
    -re {__CFG_RC__:[1-9][0-9]*} {
        send_user "\n===== ZEPHYROS CONFIG FAIL =====\n"
        exit 1
    }
    timeout {
        send_user "\n===== ZEPHYROS CONFIG TIMEOUT =====\n"
        exit 1
    }
}

expect -re {[$#] $}
send "set -o pipefail; ninja 2>&1 | tee -a \"$build_log\"; printf '\\n__BUILD_RC__:%s\\n' \$?\r"

expect {
    -re {__BUILD_RC__:0} {
        send_user "\n===== ZEPHYROS BUILD SUCCESS =====\n"
        exit 0
    }
    -re {__BUILD_RC__:[1-9][0-9]*} {
        send_user "\n===== ZEPHYROS BUILD FAIL =====\n"
        exit 1
    }
    timeout {
        send_user "\n===== ZEPHYROS BUILD TIMEOUT =====\n"
        exit 1
    }
}
EXP

    chmod +x "$expect_script"
    "$expect_script" "$repo_dir" "$pkg_version" "$build_log"
}

run_openwrt_release_core() {
    local branch=$1
    local repo_dir=$2
    local log_dir=$3
    local manifest_rel_path="include/manifest.mk"
    local manifest_file="$repo_dir/$manifest_rel_path"
    local tmp_log="$TASK_TMP_DIR/openwrt_${branch}_repo_update.log"
    local build_log="$log_dir/build.log"
    local manifest_commit_hash="SKIPPED_NO_CHANGES"
    local current_branch py_rc
    local build_start_epoch build_end_epoch build_duration_fmt

    mkdir -p "$log_dir"
    ensure_repo_parent "$repo_dir"

    echo "=========================================="
    echo " OpenWRT Release Build [$branch]"
    echo "=========================================="
    echo "Repo Dir : $repo_dir"
    echo "Log Dir  : $log_dir"
    echo

    echo "[1] 최신 hash 확인"
    echo "------------------------------------------"
    if ! collect_openwrt_repo_hashes "$tmp_log"; then
        echo "❌ openwrt 선행 repo hash 수집 실패"
        return 1
    fi

    echo "[2] openwrt clean clone"
    echo "------------------------------------------"
    rm -rf "$repo_dir"
    git clone -b "$branch" --single-branch https://release.gctsemi.com/openwrt "$repo_dir"

    current_branch="$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD)"
    if [ "$current_branch" != "$branch" ]; then
        echo "❌ openwrt 현재 branch가 예상과 다릅니다: $current_branch"
        return 1
    fi

    echo
    echo "[3] manifest.mk 수정"
    echo "------------------------------------------"
    if [ ! -f "$manifest_file" ]; then
        echo "❌ manifest 파일이 없습니다: $manifest_file"
        return 1
    fi

    update_openwrt_manifest "$manifest_file" "$PKG_VERSION"
    py_rc=$?
    if [ "$py_rc" -eq 10 ]; then
        manifest_commit_hash="SKIPPED_NO_CHANGES"
        echo "✅ manifest 값이 이미 최신값과 동일합니다."
    elif [ "$py_rc" -ne 0 ]; then
        echo "❌ manifest 수정 실패"
        return 1
    else
        echo "✅ manifest 수정 완료"
        manifest_commit_hash="UPDATED_NOT_COMMITTED"
    fi
    grep -E '^(GCT_PKG_VERSION|GDM_REPO|GDM_COMMIT|SBL_REPO|SBL_COMMIT|UBOOT_REPO|UBOOT_COMMIT):=' "$manifest_file"
    echo

    echo "[4] manifest commit / push"
    echo "------------------------------------------"
    if [ "$manifest_commit_hash" = "SKIPPED_NO_CHANGES" ]; then
        echo "manifest 값이 동일하여 commit/push 를 생략합니다."
    else
        git -C "$repo_dir" config user.name "$COMMIT_USER_NAME"
        git -C "$repo_dir" config user.email "$COMMIT_USER_EMAIL"

        echo "Commit Author"
        echo "  - Name  : $(git -C "$repo_dir" config user.name)"
        echo "  - Email : $(git -C "$repo_dir" config user.email)"
        echo

        git -C "$repo_dir" diff -- "$manifest_rel_path"
        echo

        git -C "$repo_dir" add "$manifest_rel_path"
        git -C "$repo_dir" status --short
        echo

        git -C "$repo_dir" commit -m "$COMMIT_MSG"
        manifest_commit_hash="$(git -C "$repo_dir" rev-parse HEAD)"
        echo "Manifest commit hash: $manifest_commit_hash"

        git -C "$repo_dir" push origin "$branch"
        echo "✅ manifest push 완료"
        echo "git 서버 반영 대기: 30초"
        sleep 30
    fi

    echo
    echo "[5] build용 openwrt clean clone"
    echo "------------------------------------------"
    rm -rf "$repo_dir"
    git clone -b "$branch" --single-branch https://release.gctsemi.com/openwrt "$repo_dir"

    current_branch="$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD)"
    if [ "$current_branch" != "$branch" ]; then
        echo "❌ build용 openwrt 현재 branch가 예상과 다릅니다: $current_branch"
        return 1
    fi

    echo
    echo "[6] build"
    echo "------------------------------------------"
    if [ ! -f "$repo_dir/ext-toolchain.sh" ]; then
        echo "❌ ext-toolchain.sh not found: $repo_dir/ext-toolchain.sh"
        return 1
    fi

    build_start_epoch="$(date +%s)"
    if ! run_openwrt_expect_build "$repo_dir" "$build_log" "RELEASE_BUILD_${branch}"; then
        echo "❌ OPENWRT RELEASE BUILD FAILED [$branch]"
        return 1
    fi
    build_end_epoch="$(date +%s)"
    build_duration_fmt="$(format_duration "$((build_end_epoch - build_start_epoch))")"

    {
        echo
        echo "=========================================="
        echo "Build started : $(date -d "@$build_start_epoch" '+%Y-%m-%d %H:%M:%S')"
        echo "Build ended   : $(date -d "@$build_end_epoch" '+%Y-%m-%d %H:%M:%S')"
        echo "Build duration: $build_duration_fmt"
    } >> "$build_log"

    echo
    echo "=========================================="
    echo "✅ OPENWRT RELEASE COMPLETE [$branch]"
    echo "=========================================="
    echo "GCT_PKG_VERSION: $PKG_VERSION"
    echo "Manifest Commit: $manifest_commit_hash"
    echo "Build duration : $build_duration_fmt"
    echo "Build log      : $build_log"
}

run_zephyros_release_core() {
    require_commands git expect

    local repo_dir
    local log_dir=$1
    local build_log="$log_dir/build.log"
    local build_start_epoch build_end_epoch build_duration_fmt

    repo_dir="$(repo_dir_for Zephyros)"
    mkdir -p "$log_dir"
    ensure_repo_parent "$repo_dir"

    echo "=========================================="
    echo " Zephyros Release Build"
    echo "=========================================="
    echo "Repo Dir : $repo_dir"
    echo "Log Dir  : $log_dir"
    echo

    rm -rf "$repo_dir"
    git clone https://jamesahn@vcs.gctsemi.com/OS/Zephyros "$repo_dir"

    build_start_epoch="$(date +%s)"
    if ! run_zephyros_expect_build "$repo_dir" "$PKG_VERSION" "$build_log"; then
        echo "❌ ZEPHYROS RELEASE BUILD FAILED"
        return 1
    fi
    build_end_epoch="$(date +%s)"
    build_duration_fmt="$(format_duration "$((build_end_epoch - build_start_epoch))")"

    {
        echo
        echo "=========================================="
        echo "Build started : $(date -d "@$build_start_epoch" '+%Y-%m-%d %H:%M:%S')"
        echo "Build ended   : $(date -d "@$build_end_epoch" '+%Y-%m-%d %H:%M:%S')"
        echo "Build duration: $build_duration_fmt"
    } >> "$build_log"

    echo
    echo "=========================================="
    echo "✅ ZEPHYROS RELEASE COMPLETE"
    echo "=========================================="
    echo "Build duration : $build_duration_fmt"
    echo "Build log      : $build_log"
}

run_zephyros_nsa_task() {
    require_commands git expect

    local repo_dir log_dir build_log
    local build_start_epoch build_end_epoch build_duration_fmt

    repo_dir="$(repo_dir_for Zephyros)"
    log_dir="$LOG_DIR"
    build_log="$log_dir/build.log"

    mkdir -p "$log_dir"
    ensure_repo_parent "$repo_dir"

    echo "=========================================="
    echo " Zephyros GDM7275x_nsa build"
    echo "=========================================="
    echo "Repo Dir : $repo_dir"
    echo "Log Dir  : $log_dir"
    echo

    rm -rf "$repo_dir"
    git clone https://jamesahn@vcs.gctsemi.com/OS/Zephyros "$repo_dir"

    build_start_epoch="$(date +%s)"
    if ! run_zephyros_expect_build "$repo_dir" "" "$build_log"; then
        echo "❌ ZEPHYROS GDM7275x_nsa BUILD FAILED"
        return 1
    fi
    build_end_epoch="$(date +%s)"
    build_duration_fmt="$(format_duration "$((build_end_epoch - build_start_epoch))")"

    {
        echo
        echo "=========================================="
        echo "Build started : $(date -d "@$build_start_epoch" '+%Y-%m-%d %H:%M:%S')"
        echo "Build ended   : $(date -d "@$build_end_epoch" '+%Y-%m-%d %H:%M:%S')"
        echo "Build duration: $build_duration_fmt"
    } >> "$build_log"

    echo
    echo "=========================================="
    echo "✅ ZEPHYROS GDM7275x_nsa BUILD COMPLETE"
    echo "=========================================="
    echo "Build duration : $build_duration_fmt"
    echo "Build log      : $build_log"
}

run_zephyros_nsa_pkgver_task() {
    require_commands git expect

    local repo_dir log_dir build_log
    local build_start_epoch build_end_epoch build_duration_fmt

    repo_dir="$(repo_dir_for Zephyros)"
    log_dir="$LOG_DIR"
    build_log="$log_dir/build.log"

    mkdir -p "$log_dir"
    ensure_repo_parent "$repo_dir"

    echo "=========================================="
    echo " Zephyros GDM7275x_nsa build with PKGVER"
    echo "=========================================="
    echo "Repo Dir : $repo_dir"
    echo "Log Dir  : $log_dir"
    echo "PKG Ver  : $PKG_VERSION"
    echo

    rm -rf "$repo_dir"
    git clone https://jamesahn@vcs.gctsemi.com/OS/Zephyros "$repo_dir"

    build_start_epoch="$(date +%s)"
    if ! run_zephyros_expect_build "$repo_dir" "$PKG_VERSION" "$build_log"; then
        echo "❌ ZEPHYROS GDM7275x_nsa PKGVER BUILD FAILED"
        return 1
    fi
    build_end_epoch="$(date +%s)"
    build_duration_fmt="$(format_duration "$((build_end_epoch - build_start_epoch))")"

    {
        echo
        echo "=========================================="
        echo "Build started : $(date -d "@$build_start_epoch" '+%Y-%m-%d %H:%M:%S')"
        echo "Build ended   : $(date -d "@$build_end_epoch" '+%Y-%m-%d %H:%M:%S')"
        echo "Build duration: $build_duration_fmt"
    } >> "$build_log"

    echo
    echo "=========================================="
    echo "✅ ZEPHYROS GDM7275x_nsa PKGVER BUILD COMPLETE"
    echo "=========================================="
    echo "Build duration : $build_duration_fmt"
    echo "Build log      : $build_log"
}

run_openwrt_official_release_task() {
    require_commands git python3 expect

    local master_repo v100_repo zephyros_repo summary_file
    local master_log_dir v100_log_dir zephyros_log_dir
    local master_rc v100_rc zephyros_rc overall_rc=0
    local master_pid v100_pid zephyros_pid

    master_repo="$(repo_dir_for openwrt master)"
    v100_repo="$(repo_dir_for openwrt v1.00)"
    zephyros_repo="$(repo_dir_for Zephyros)"
    master_log_dir="$LOG_DIR/openwrt_master"
    v100_log_dir="$LOG_DIR/openwrt_v1.00"
    zephyros_log_dir="$LOG_DIR/zephyros"
    summary_file="$LOG_DIR/summary.log"

    mkdir -p "$master_log_dir" "$v100_log_dir" "$zephyros_log_dir"

    echo "=========================================="
    echo " OpenWRT Official Release"
    echo "=========================================="
    echo "Pkg Ver   : $PKG_VERSION"
    echo "Committer : $COMMIT_USER_NAME <$COMMIT_USER_EMAIL>"
    echo "Message   : $COMMIT_MSG"
    echo "Log Dir   : $LOG_DIR"
    echo

    (
        run_openwrt_release_core "master" "$master_repo" "$master_log_dir"
    ) >"$master_log_dir/console.log" 2>&1 &
    master_pid=$!

    (
        run_openwrt_release_core "v1.00" "$v100_repo" "$v100_log_dir"
    ) >"$v100_log_dir/console.log" 2>&1 &
    v100_pid=$!

    (
        run_zephyros_release_core "$zephyros_log_dir"
    ) >"$zephyros_log_dir/console.log" 2>&1 &
    zephyros_pid=$!

    wait "$master_pid" || master_rc=$?
    master_rc=${master_rc:-0}
    wait "$v100_pid" || v100_rc=$?
    v100_rc=${v100_rc:-0}
    wait "$zephyros_pid" || zephyros_rc=$?
    zephyros_rc=${zephyros_rc:-0}

    {
        echo "=========================================="
        echo " Official Release Summary"
        echo "=========================================="
        echo "openwrt master : rc=$master_rc log=$master_log_dir/console.log"
        echo "openwrt v1.00  : rc=$v100_rc log=$v100_log_dir/console.log"
        echo "Zephyros       : rc=$zephyros_rc log=$zephyros_log_dir/console.log"
    } | tee "$summary_file"

    [ "$master_rc" -eq 0 ] || overall_rc=1
    [ "$v100_rc" -eq 0 ] || overall_rc=1
    [ "$zephyros_rc" -eq 0 ] || overall_rc=1

    if [ "$overall_rc" -ne 0 ]; then
        echo "❌ Official release 중 일부 작업이 실패했습니다."
        return 1
    fi

    echo "✅ Official release 작업이 모두 완료되었습니다."
}

append_linuxos_commit_details() {
    local repo_dir=$1
    local failure_report=$2
    local count=$3
    shift 3
    local commit

    while IFS= read -r commit; do
        [ -n "$commit" ] || continue
        {
            echo "commit $commit"
            git -C "$repo_dir" show --stat --summary --date=iso-strict --format='Author: %an <%ae>%nDate:   %ad%nSubject: %s' --no-patch "$commit" || true
            echo
            git -C "$repo_dir" show --stat --summary --date=iso-strict --format='' "$commit" | sed '/^$/d' || true
            echo
        } >> "$failure_report"
    done < <(git -C "$repo_dir" log --format='%H' -n "$count" -- "$@" 2>/dev/null || true)
}

analyze_linuxos_failure() {
    local repo_dir=$1
    local build_log=$2
    local verbose_log=$3
    local failure_report=$4
    local source_log first_fatal source_path resolved_source_path rel_path header_path candidate

    source_log="$verbose_log"
    if [ ! -f "$source_log" ] || [ ! -s "$source_log" ]; then
        source_log="$build_log"
    fi

    {
        echo "=========================================="
        echo "LinuxOS Build Failure Report"
        echo "=========================================="
        echo "Repo path      : $repo_dir"
        echo "Build log      : $build_log"
        echo "Verbose log    : $verbose_log"
        echo "Source log     : $source_log"
        echo "Generated at   : $(date '+%Y-%m-%d %H:%M:%S')"
        echo
        echo "[Recent errors]"
        grep -nE 'fatal error:|error:|No such file or directory|cannot find|undefined reference|make(\[[0-9]+\])?: \*\*\*' "$source_log" | tail -n 40 || true
        echo
    } > "$failure_report"

    first_fatal="$(grep -m 1 'fatal error:' "$source_log" || true)"
    if [ -n "$first_fatal" ]; then
        source_path="$(printf '%s\n' "$first_fatal" | sed -E 's#^([^:]+):[0-9]+:.*#\1#')"
        header_path="$(printf '%s\n' "$first_fatal" | sed -E 's#^.*fatal error: ([^:]+):.*#\1#')"
        resolved_source_path=""

        {
            echo "[First fatal error]"
            echo "$first_fatal"
            echo
        } >> "$failure_report"

        if [ -n "$source_path" ]; then
            if [ -f "$source_path" ]; then
                resolved_source_path="$source_path"
            elif [[ "$source_path" == ../* ]]; then
                candidate="$(find "$repo_dir/user" -type f -path "*/${source_path#../}" 2>/dev/null | head -n 1 || true)"
                if [ -n "$candidate" ]; then
                    resolved_source_path="$candidate"
                fi
            fi
        fi

        if [ -n "$resolved_source_path" ] && [ -f "$resolved_source_path" ]; then
            rel_path="${resolved_source_path#$repo_dir/}"
            {
                echo "[Resolved source path]"
                echo "$resolved_source_path"
                echo
                echo "[Git log: $rel_path]"
                git -C "$repo_dir" log --oneline -n 15 -- "$rel_path" || true
                echo
                echo "[Recent commit details: $rel_path]"
                append_linuxos_commit_details "$repo_dir" "$failure_report" 5 "$rel_path"
                echo "[Git blame: $rel_path]"
                git -C "$repo_dir" blame -L 1,80 -- "$rel_path" || true
                echo
            } >> "$failure_report"
        else
            {
                echo "[Resolved source path]"
                echo "Unable to resolve source path from fatal line: $source_path"
                echo
            } >> "$failure_report"
        fi

        if [ -n "$header_path" ]; then
            {
                echo "[Missing header search: $header_path]"
                find "$repo_dir" -path "$repo_dir/.git" -prune -o -type f \( -path "*/$header_path" -o -name "$(basename "$header_path")" \) -print 2>/dev/null || true
                echo
                echo "[Header references]"
                grep -Rsn --include='*.c' --include='*.h' --include='*.mk' --include='Makefile*' "$header_path" "$repo_dir" 2>/dev/null | head -n 40 || true
                echo
            } >> "$failure_report"
        fi
    fi

    {
        echo "[Recent commits touching hostapd/libnl-related paths]"
        git -C "$repo_dir" log --oneline -n 20 -- user/hostapd-2.10 user/hostapd-2.11 config 2>/dev/null || true
        echo
        echo "[Detailed recent commits touching hostapd/libnl-related paths]"
    } >> "$failure_report"
    append_linuxos_commit_details "$repo_dir" "$failure_report" 5 user/hostapd-2.10 user/hostapd-2.11 config
}

run_linuxos_expect_build() {
    local repo_dir=$1
    local build_log=$2
    local verbose_log=$3
    local expect_script="$TASK_TMP_DIR/linuxos_make_config.exp"

    cat > "$expect_script" <<'EXP'
#!/usr/bin/expect -f
set timeout -1
log_user 1

set build_dir [lindex $argv 0]
set build_log [lindex $argv 1]
set verbose_log [lindex $argv 2]

set choice_answers {11 1 1}
set choice_index 0

proc next_choice {choicesVar indexVar} {
    upvar $choicesVar choices
    upvar $indexVar index

    if {$index >= [llength $choices]} {
        send_user "\n===== UNEXPECTED CHOICE PROMPT =====\n"
        exit 1
    }

    set answer [lindex $choices $index]
    incr index
    send -- "$answer\r"
}

spawn bash

expect -re {[$#] $}
send -- "cd -- \"$build_dir\"\r"

expect -re {[$#] $}
send -- "set -o pipefail; make config 2>&1 | tee -a \"$build_log\"; printf '\\n__CONFIG_RC__:%s\\n' \$?\r"

expect_before {
    -re {Default all settings .*([:]|\(NEW\))\s*$} { send -- "y\r"; exp_continue }
    -re {Customize Kernel Settings .*([:]|\(NEW\))\s*$} { send -- "n\r"; exp_continue }
    -re {Customize Application/Library Settings .*([:]|\(NEW\))\s*$} { send -- "n\r"; exp_continue }
    -re {Update Default Vendor Settings .*([:]|\(NEW\))\s*$} { send -- "n\r"; exp_continue }
    -re {choice\[[0-9\-?]+\]:\s*$} { next_choice choice_answers choice_index; exp_continue }
    -re {\[[^]]+\]\s*$} { send -- "\r"; exp_continue }
}

expect {
    -re {__CONFIG_RC__:0} {
        send_user "\n===== LINUXOS CONFIG SUCCESS =====\n"
    }
    -re {__CONFIG_RC__:[1-9][0-9]*} {
        send_user "\n===== LINUXOS CONFIG FAIL =====\n"
        exit 1
    }
    timeout {
        send_user "\n===== LINUXOS CONFIG TIMEOUT =====\n"
        exit 1
    }
}

expect -re {[$#] $}
send -- "cd -- \"$build_dir\" && set -o pipefail; make 2>&1 | tee -a \"$build_log\"; printf '\\n__BUILD_RC__:%s\\n' \$?\r"

expect {
    -re {__BUILD_RC__:0} {
        send_user "\n===== LINUXOS BUILD SUCCESS =====\n"
        exit 0
    }
    -re {__BUILD_RC__:[1-9][0-9]*} {
        send_user "\n===== LINUXOS BUILD FAIL =====\n"
    }
    timeout {
        send_user "\n===== LINUXOS BUILD TIMEOUT =====\n"
        exit 1
    }
}

expect -re {[$#] $}
send -- "cd -- \"$build_dir\" && set -o pipefail; echo '===== RETRY WITH V=sc =====' | tee -a \"$verbose_log\"; make V=sc 2>&1 | tee -a \"$verbose_log\"; printf '\\n__BUILD_RC__:%s\\n' \$?\r"

expect {
    -re {__BUILD_RC__:0} {
        send_user "\n===== LINUXOS BUILD SUCCESS (V=sc) =====\n"
        exit 0
    }
    -re {__BUILD_RC__:[1-9][0-9]*} {
        send_user "\n===== LINUXOS BUILD FAIL (V=sc) =====\n"
        exit 1
    }
    timeout {
        send_user "\n===== LINUXOS BUILD TIMEOUT (V=sc) =====\n"
        exit 1
    }
}
EXP

    chmod +x "$expect_script"
    "$expect_script" "$repo_dir" "$build_log" "$verbose_log"
}

run_openwrt_task() {
    require_commands git python3 expect

    local branch=$BRANCH
    local job=$JOB
    local repo_dir=$REPO_DIR
    local manifest_rel_path="include/manifest.mk"
    local manifest_file="$repo_dir/$manifest_rel_path"
    local tmp_log="$TASK_TMP_DIR/openwrt_repo_update.log"
    local build_log="$LOG_DIR/build.log"
    local build_start_epoch build_end_epoch build_duration_fmt manifest_commit_hash current_branch py_rc

    ensure_repo_parent "$repo_dir"

    echo "=========================================="
    echo " OpenWRT Task"
    echo "=========================================="
    echo "Branch   : $branch"
    echo "Job      : $job"
    echo "Repo Dir : $repo_dir"
    echo "Log Dir  : $LOG_DIR"
    echo

    echo "[1] 최신 hash 확인"
    echo "------------------------------------------"
    if ! collect_openwrt_repo_hashes "$tmp_log"; then
        echo "❌ openwrt 선행 repo hash 수집 실패"
        return 1
    fi
    manifest_commit_hash="SKIPPED_NO_CHANGES"

    echo "[2] openwrt clean clone"
    echo "------------------------------------------"
    rm -rf "$repo_dir"
    git clone -b "$branch" --single-branch https://release.gctsemi.com/openwrt "$repo_dir"

    current_branch="$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD)"
    if [ "$current_branch" != "$branch" ]; then
        echo "❌ openwrt 현재 branch가 예상과 다릅니다: $current_branch"
        return 1
    fi

    echo
    echo "[3] manifest.mk 수정"
    echo "------------------------------------------"
    if [ ! -f "$manifest_file" ]; then
        echo "❌ manifest 파일이 없습니다: $manifest_file"
        return 1
    fi

    update_openwrt_manifest "$manifest_file" "$PKG_VERSION"
    py_rc=$?
    if [ "$py_rc" -eq 10 ]; then
        manifest_commit_hash="SKIPPED_NO_CHANGES"
        echo "✅ manifest 값이 이미 최신값과 동일합니다."
    elif [ "$py_rc" -ne 0 ]; then
        echo "❌ manifest 수정 실패"
        return 1
    else
        echo "✅ manifest 수정 완료"
        manifest_commit_hash="UPDATED_NOT_COMMITTED"
    fi
    grep -E '^(GCT_PKG_VERSION|GDM_REPO|GDM_COMMIT|SBL_REPO|SBL_COMMIT|UBOOT_REPO|UBOOT_COMMIT):=' "$manifest_file"
    echo

    if [ "$job" = "release_build" ]; then
        echo "[4] manifest commit / push"
        echo "------------------------------------------"

        if [ "$manifest_commit_hash" = "SKIPPED_NO_CHANGES" ]; then
            echo "manifest 값이 동일하여 commit/push 를 생략합니다."
        else
            git -C "$repo_dir" config user.name "$COMMIT_USER_NAME"
            git -C "$repo_dir" config user.email "$COMMIT_USER_EMAIL"

            echo "Commit Author"
            echo "  - Name  : $(git -C "$repo_dir" config user.name)"
            echo "  - Email : $(git -C "$repo_dir" config user.email)"
            echo

            git -C "$repo_dir" diff -- "$manifest_rel_path"
            echo

            git -C "$repo_dir" add "$manifest_rel_path"
            git -C "$repo_dir" status --short
            echo

            git -C "$repo_dir" commit -m "$COMMIT_MSG"
            manifest_commit_hash="$(git -C "$repo_dir" rev-parse HEAD)"
            echo "Manifest commit hash: $manifest_commit_hash"

            git -C "$repo_dir" push origin "$branch"
            echo "✅ manifest push 완료"
            echo "git 서버 반영 대기: 30초"
            sleep 30
        fi
    fi

    if [ "$job" = "dirty_clone" ]; then
        echo
        echo "=========================================="
        echo "✅ DIRTY CLONE COMPLETE"
        echo "=========================================="
        echo "Repo Dir : $repo_dir"
        return 0
    fi

    echo
    echo "[5] build"
    echo "------------------------------------------"
    if [ ! -f "$repo_dir/ext-toolchain.sh" ]; then
        echo "❌ ext-toolchain.sh not found: $repo_dir/ext-toolchain.sh"
        return 1
    fi

    build_start_epoch="$(date +%s)"
    if [ "$job" = "release_build" ]; then
        if ! run_openwrt_expect_build "$repo_dir" "$build_log" "RELEASE_BUILD"; then
            echo "❌ OPENWRT RELEASE BUILD FAILED"
            return 1
        fi
    else
        if ! run_openwrt_expect_build "$repo_dir" "$build_log" "DIRTY_BUILD"; then
            echo "❌ OPENWRT DIRTY BUILD FAILED"
            return 1
        fi
    fi
    build_end_epoch="$(date +%s)"
    build_duration_fmt="$(format_duration "$((build_end_epoch - build_start_epoch))")"

    {
        echo
        echo "=========================================="
        echo "Build started : $(date -d "@$build_start_epoch" '+%Y-%m-%d %H:%M:%S')"
        echo "Build ended   : $(date -d "@$build_end_epoch" '+%Y-%m-%d %H:%M:%S')"
        echo "Build duration: $build_duration_fmt"
    } >> "$build_log"

    echo
    echo "=========================================="
    echo "✅ OPENWRT TASK COMPLETE"
    echo "=========================================="
    echo "Branch         : $branch"
    echo "Job            : $job"
    echo "GCT_PKG_VERSION: $PKG_VERSION"
    echo "Manifest Commit: $manifest_commit_hash"
    echo "GDM_BRANCH     : $GDM_BRANCH"
    echo "GDM_COMMIT     : $GDM_COMMIT"
    echo "SBL_BRANCH     : $SBL_BRANCH"
    echo "SBL_COMMIT     : $SBL_COMMIT"
    echo "UBOOT_BRANCH   : $UBOOT_BRANCH"
    echo "UBOOT_COMMIT   : $UBOOT_COMMIT"
    echo "Build duration : $build_duration_fmt"
    echo "Build log      : $build_log"
}

run_linuxos_task() {
    require_commands git expect tmux

    local repo_dir=$REPO_DIR
    local build_log="$LOG_DIR/build.log"
    local verbose_log="$LOG_DIR/build_verbose.log"
    local failure_report="$LOG_DIR/failure_report.log"
    local build_start_epoch build_end_epoch build_duration_fmt current_branch

    ensure_repo_parent "$repo_dir"

    echo "=========================================="
    echo " LinuxOS master build"
    echo "=========================================="
    echo "Repo path  : $repo_dir"
    echo "Run dir    : $LOG_DIR"
    echo "Build log  : $build_log"
    echo "Verbose log: $verbose_log"
    echo "Failure rpt: $failure_report"
    echo

    echo "[1] 기존 repo 경로 확인"
    echo "------------------------------------------"
    if [ -d "$repo_dir" ]; then
        echo ">> 기존 '$repo_dir' 폴더가 발견되었습니다. 삭제를 진행합니다..."
        rm -rf "$repo_dir"
        echo ">> 삭제 완료."
    else
        echo ">> 기존 repo 없음."
    fi

    echo
    echo "[2] linuxos master clone"
    echo "------------------------------------------"
    git clone -b "$BRANCH" --single-branch https://release.gctsemi.com/linuxos "$repo_dir"

    echo
    echo "[3] clone 완료 후 repo 진입"
    echo "------------------------------------------"
    current_branch="$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD)"
    if [ "$current_branch" != "$BRANCH" ]; then
        echo "❌ 현재 branch가 예상과 다릅니다: $current_branch"
        return 1
    fi
    echo ">> 현재 경로   : $repo_dir"
    echo ">> 현재 branch : $current_branch"

    echo
    echo "[4] make config 자동 입력"
    echo "------------------------------------------"
    if ! run_linuxos_expect_build "$repo_dir" "$build_log" "$verbose_log"; then
        analyze_linuxos_failure "$repo_dir" "$build_log" "$verbose_log" "$failure_report"
        echo
        echo "❌ BUILD FAILED"
        echo "Failure report: $failure_report"
        return 1
    fi

    if ! grep -q '^CONFIG_DEFAULTS_GCT_GDM7275X=y$' "$repo_dir/.config"; then
        echo
        echo "❌ make config 결과가 gdm7275x로 설정되지 않았습니다."
        echo "[Selected product in .config]"
        grep -n 'CONFIG_DEFAULTS_GCT_GDM[0-9A-Z_]*=' "$repo_dir/.config" || true
        return 1
    fi

    build_start_epoch="$(date +%s)"

    build_end_epoch="$(date +%s)"
    build_duration_fmt="$(format_duration "$((build_end_epoch - build_start_epoch))")"

    {
        echo
        echo "=========================================="
        echo "Build started : $(date -d "@$build_start_epoch" '+%Y-%m-%d %H:%M:%S')"
        echo "Build ended   : $(date -d "@$build_end_epoch" '+%Y-%m-%d %H:%M:%S')"
        echo "Build duration: $build_duration_fmt"
    } | tee -a "$build_log"

    echo
    echo "=========================================="
    echo "✅ BUILD COMPLETE"
    echo "=========================================="
    echo "Build duration : $build_duration_fmt"
    echo "Build log      : $build_log"
    echo "Verbose log    : $verbose_log"
    echo "Failure report : $failure_report"
}

run_release_note_task() {
    require_commands git

    local input_date=$INPUT_DATE
    local week_tag now since master_out_file v100_out_file

    if ! date -d "$input_date" '+%Y-%m-%d' >/dev/null 2>&1; then
        echo "❌ 날짜 형식이 올바르지 않습니다. 예: 2026-04-10"
        return 1
    fi

    week_tag="$(date +%yW%V)"
    now="$(date '+%Y-%m-%d %H:%M:%S')"
    since="$(date -d "$input_date" '+%Y-%m-%d 00:00:00')"
    master_out_file="$LOG_DIR/Release_note_master_${week_tag}.log"
    v100_out_file="$LOG_DIR/Release_note_v1.00_${week_tag}.log"

    generate_release_note_file() {
        local out_file=$1
        local openwrt_disp=$2
        local openwrt_branch=$3
        {
            echo "Release note $week_tag"
            echo "Range: $since ~ $now"
            echo
            echo "[AP]"
            write_release_note_repo_log "$since" "$now" "$openwrt_disp" "openwrt" "$openwrt_branch"
            local entry disp repo_key branch
            for entry in "${RELEASE_NOTE_COMMON_AP_REPOS[@]}"; do
                IFS='|' read -r disp repo_key branch <<< "$entry"
                write_release_note_repo_log "$since" "$now" "$disp" "$repo_key" "$branch"
            done
            echo
            echo "[CP]"
            for entry in "${RELEASE_NOTE_CP_REPOS[@]}"; do
                IFS='|' read -r disp repo_key branch <<< "$entry"
                write_release_note_repo_log "$since" "$now" "$disp" "$repo_key" "$branch"
            done
        } > "$out_file"
    }

    generate_release_note_file "$master_out_file" "openwrt master" "master"
    generate_release_note_file "$v100_out_file" "openwrt v1.00" "v1.00"

    echo "✅ Release note 생성 완료: $master_out_file"
    echo "✅ Release note 생성 완료: $v100_out_file"
    echo "Range: $since ~ $now"
}

run_repo_hash_check_task() {
    require_commands git

    echo "=========================================="
    echo " Current Repository Hash Checker"
    echo "=========================================="
    echo

    local tmp_log="$TASK_TMP_DIR/repo_hash_check.log"
    local entry
    for entry in "${REPO_HASH_TARGETS[@]}"; do
        local disp repo_key check_branch repo_dir branch hash
        IFS='|' read -r disp repo_key check_branch <<< "$entry"
        repo_dir="$(repo_dir_for "$repo_key" "$check_branch")"

        echo "[$disp]"
        if [ ! -d "$repo_dir" ]; then
            echo "  - 폴더 없음: $repo_dir"
            echo
            continue
        fi

        if [ ! -d "$repo_dir/.git" ]; then
            echo "  - git repo 아님: $repo_dir"
            echo
            continue
        fi

        if [ -n "$check_branch" ]; then
            branch="origin/$check_branch"
            git -C "$repo_dir" fetch origin "+refs/heads/$check_branch:refs/remotes/origin/$check_branch" > "$tmp_log" 2>&1
        else
            branch="$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
            git -C "$repo_dir" pull --ff-only > "$tmp_log" 2>&1
        fi

        if [ -s "$tmp_log" ]; then
            echo "  - Update : $(tail -n 1 "$tmp_log")"
        else
            echo "  - Update : 완료"
        fi

        hash="$(git -C "$repo_dir" rev-parse "${branch:-HEAD}" 2>/dev/null || true)"
        if [ -n "$hash" ]; then
            echo "  - Branch : ${branch:-HEAD}"
            echo "  - Hash   : $hash"
        else
            echo "  - git hash 조회 실패"
        fi
        echo
    done
}

run_repo_clone_task() {
    require_commands git

    local repo_display=$REPO_DISPLAY
    local repo_url=$REPO_URL
    local repo_branch="${REPO_BRANCH:-}"
    local repo_dir=$REPO_DIR

    ensure_repo_parent "$repo_dir"

    echo "=========================================="
    echo " Repository Clone"
    echo "=========================================="
    echo "Target   : $repo_display"
    echo "Repo URL : $repo_url"
    if [ -n "$repo_branch" ]; then
        echo "Branch   : $repo_branch"
    else
        echo "Branch   : default"
    fi
    echo "Repo Dir : $repo_dir"
    echo

    if [ -d "$repo_dir" ]; then
        echo ">> 기존 '$repo_dir' 폴더가 발견되었습니다. 삭제를 진행합니다..."
        rm -rf "$repo_dir"
        echo ">> 삭제 완료."
    else
        echo ">> 기존 repo 없음."
    fi

    echo
    echo ">> 새 clone 시작"
    if [ -n "$repo_branch" ]; then
        git clone -b "$repo_branch" --single-branch "$repo_url" "$repo_dir"
    else
        git clone "$repo_url" "$repo_dir"
    fi

    echo
    echo "✅ Repository clone complete"
    echo "Target   : $repo_display"
    echo "Repo Dir : $repo_dir"
}

run_task_by_id() {
    local task_id=$1
    local task_file config_file

    init_workspace
    task_file="$(task_file_path "$task_id")"
    config_file="$(task_config_path "$task_id")"
    if [ ! -f "$task_file" ]; then
        echo "❌ task file not found: $task_file"
        exit 1
    fi

    load_env_file "$task_file"
    load_env_file "$config_file"

    TASK_TMP_DIR="$TMP_ROOT/$TASK_ID"
    mkdir -p "$TASK_TMP_DIR" "$LOG_DIR"

    set_kv_in_file "$task_file" "STATUS" "RUNNING"
    set_kv_in_file "$task_file" "STARTED_AT" "$(date '+%Y-%m-%d %H:%M:%S')"
    set_kv_in_file "$task_file" "START_EPOCH" "$(date +%s)"

    exec > >(tee -a "$LOG_DIR/console.log") 2>&1

    local rc=0
    case "$PROJECT:$JOB" in
        openwrt:official_release)
            run_openwrt_official_release_task || rc=$?
            ;;
        openwrt:release_build|openwrt:dirty_build|openwrt:dirty_clone)
            run_openwrt_task || rc=$?
            ;;
        zephyros:gdm7275x_nsa_build)
            run_zephyros_nsa_task || rc=$?
            ;;
        zephyros:gdm7275x_nsa_pkgver_build)
            run_zephyros_nsa_pkgver_task || rc=$?
            ;;
        linuxos:dirty_build)
            run_linuxos_task || rc=$?
            ;;
        release_note:generate)
            run_release_note_task || rc=$?
            ;;
        utility:repo_clone)
            run_repo_clone_task || rc=$?
            ;;
        utility:repo_hash_check)
            run_repo_hash_check_task || rc=$?
            ;;
        *)
            echo "❌ Unsupported task: $PROJECT / $JOB"
            rc=1
            ;;
    esac

    set_kv_in_file "$task_file" "ENDED_AT" "$(date '+%Y-%m-%d %H:%M:%S')"
    set_kv_in_file "$task_file" "END_EPOCH" "$(date +%s)"
    if [ "$rc" -eq 0 ]; then
        set_kv_in_file "$task_file" "STATUS" "SUCCESS"
    else
        set_kv_in_file "$task_file" "STATUS" "FAIL"
    fi
    archive_task "$task_id"
    exit "$rc"
}

openwrt_menu() {
    while true; do
        print_main_header
        echo "[OpenWRT]"
        echo "1) Official release"
        echo "2) OpenWRT master build"
        echo "3) OpenWRT v1.00 build"
        echo "4) Back"
        echo

        case "$(prompt_dashboard_choice "Select: ")" in
            1)
                openwrt_official_release_menu
                ;;
            2)
                openwrt_single_build_menu "master"
                ;;
            3)
                openwrt_single_build_menu "v1.00"
                ;;
            4)
                return 0
                ;;
            __REFRESH__)
                ;;
            *)
                ;;
        esac
    done
}

openwrt_single_build_menu() {
    local branch=$1
    local repo_dir pkg_version

    repo_dir="$(repo_dir_for openwrt "$branch")"
    pkg_version="$(prompt_non_empty "GCT_PKG_VERSION 입력: ")"

    echo
    echo "Project  : openwrt"
    echo "Task     : $(task_display_name openwrt dirty_build "$branch")"
    echo "Branch   : $branch"
    echo "Repo Dir : $repo_dir"
    echo "Pkg Ver  : $pkg_version"
    echo

    case "$(prompt_menu_choice "1) Run  2) Cancel : ")" in
        1)
            launch_task "openwrt" "dirty_build" "$branch" "$repo_dir" \
                "PKG_VERSION" "$pkg_version"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

openwrt_official_release_menu() {
    local master_repo v100_repo zephyros_repo pkg_version commit_msg

    master_repo="$(repo_dir_for openwrt master)"
    v100_repo="$(repo_dir_for openwrt v1.00)"
    zephyros_repo="$(repo_dir_for Zephyros)"

    if ! ensure_repo_paths_available "$master_repo" "$v100_repo" "$zephyros_repo"; then
        pause_enter
        return 1
    fi

    pkg_version="$(prompt_non_empty "GCT_PKG_VERSION 입력: ")"
    select_commit_user
    commit_msg="$(prompt_non_empty "Commit message 입력: ")"

    echo
    echo "Project        : openwrt"
    echo "Task           : $(task_display_name openwrt official_release multi)"
    echo "OpenWRT master : $master_repo"
    echo "OpenWRT v1.00  : $v100_repo"
    echo "Zephyros       : $zephyros_repo"
    echo "Pkg Ver        : $pkg_version"
    echo "Committer      : $COMMIT_USER_NAME <$COMMIT_USER_EMAIL>"
    echo "Message        : $commit_msg"
    echo

    case "$(prompt_menu_choice "1) Run  2) Cancel : ")" in
        1)
            launch_task "openwrt" "official_release" "multi" "" \
                "PKG_VERSION" "$pkg_version" \
                "COMMIT_USER_NAME" "$COMMIT_USER_NAME" \
                "COMMIT_USER_EMAIL" "$COMMIT_USER_EMAIL" \
                "COMMIT_MSG" "$commit_msg" \
                "RESERVED_REPO_DIRS" "$master_repo:$v100_repo:$zephyros_repo"
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

linuxos_menu() {
    while true; do
        print_main_header
        echo "[LinuxOS]"
        echo "1) LinuxOS master build"
        echo "2) Back"
        echo

        case "$(prompt_dashboard_choice "Select: ")" in
            1)
                local repo_dir
                repo_dir="$(repo_dir_for linuxos master)"
                echo
                echo "Project  : linuxos"
                echo "Task     : $(task_display_name linuxos dirty_build master)"
                echo "Branch   : master"
                echo "Repo Dir : $repo_dir"
                echo
                case "$(prompt_menu_choice "1) Run  2) Cancel : ")" in
                    1)
                        launch_task "linuxos" "dirty_build" "master" "$repo_dir"
                        return 0
                        ;;
                    *)
                        ;;
                esac
                ;;
            2)
                return 0
                ;;
            __REFRESH__)
                ;;
            *)
                ;;
        esac
    done
}

zephyros_menu() {
    while true; do
        print_main_header
        echo "[Zephyros]"
        echo "1) GDM7275x_nsa build"
        echo "2) GDM7275x_nsa build with PKGVER"
        echo "3) Back"
        echo

        case "$(prompt_dashboard_choice "Select: ")" in
            1)
                local repo_dir
                repo_dir="$(repo_dir_for Zephyros)"
                echo
                echo "Project  : zephyros"
                echo "Task     : $(task_display_name zephyros gdm7275x_nsa_build default)"
                echo "Repo Dir : $repo_dir"
                echo
                case "$(prompt_menu_choice "1) Run  2) Cancel : ")" in
                    1)
                        launch_task "zephyros" "gdm7275x_nsa_build" "default" "$repo_dir"
                        return 0
                        ;;
                    *)
                        ;;
                esac
                ;;
            2)
                local repo_dir pkg_version
                repo_dir="$(repo_dir_for Zephyros)"
                pkg_version="$(prompt_non_empty "PKG_VERSION 입력: ")"
                echo
                echo "Project  : zephyros"
                echo "Task     : $(task_display_name zephyros gdm7275x_nsa_pkgver_build default)"
                echo "Repo Dir : $repo_dir"
                echo "PKG Ver  : $pkg_version"
                echo
                case "$(prompt_menu_choice "1) Run  2) Cancel : ")" in
                    1)
                        launch_task "zephyros" "gdm7275x_nsa_pkgver_build" "default" "$repo_dir" \
                            "PKG_VERSION" "$pkg_version"
                        return 0
                        ;;
                    *)
                        ;;
                esac
                ;;
            3)
                return 0
                ;;
            __REFRESH__)
                ;;
            *)
                ;;
        esac
    done
}

release_note_menu() {
    while true; do
        print_main_header
        echo "[Release Note]"
        echo "1) Generate From Date"
        echo "2) Back"
        echo

        case "$(prompt_dashboard_choice "Select: ")" in
            1)
                local input_date
                input_date="$(prompt_non_empty "기준 날짜 입력 (YYYY-MM-DD): ")"
                echo
                echo "Project : release_note"
                echo "Job     : generate"
                echo "Date    : $input_date"
                echo "Log Dir : $LOG_ROOT/release_note/generate/default/<run_id>"
                echo
                case "$(prompt_menu_choice "1) Run  2) Cancel : ")" in
                    1)
                        launch_task "release_note" "generate" "default" "" \
                            "INPUT_DATE" "$input_date"
                        return 0
                        ;;
                    *)
                        ;;
                esac
                ;;
            2)
                return 0
                ;;
            __REFRESH__)
                ;;
            *)
                ;;
        esac
    done
}

repository_clone_menu() {
    while true; do
        print_main_header
        echo "[Repository Clone]"

        local i disp repo_key repo_branch repo_url choice choice_index repo_dir repo_id
        for i in "${!REPOSITORY_CLONE_TARGETS[@]}"; do
            IFS='|' read -r disp repo_key repo_branch repo_url <<< "${REPOSITORY_CLONE_TARGETS[$i]}"
            printf '%d) %s\n' "$((i + 1))" "$disp"
        done
        echo "$(( ${#REPOSITORY_CLONE_TARGETS[@]} + 1 ))) Back"
        echo

        choice="$(prompt_dashboard_choice "Select: ")"
        case "$choice" in
            __REFRESH__)
                ;;
            *)
                if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
                    continue
                fi
                if [ "$choice" = "$(( ${#REPOSITORY_CLONE_TARGETS[@]} + 1 ))" ]; then
                    return 0
                fi
                choice_index=$(( choice - 1 ))
                if [ "$choice_index" -ge 0 ] && [ "$choice_index" -lt "${#REPOSITORY_CLONE_TARGETS[@]}" ]; then
                    IFS='|' read -r disp repo_key repo_branch repo_url <<< "${REPOSITORY_CLONE_TARGETS[$choice_index]}"
                    repo_dir="$(repo_dir_for "$repo_key" "$repo_branch")"
                    repo_id="$(printf '%s_%s' "$repo_key" "${repo_branch:-default}" | tr '.-' '__' | tr '[:upper:]' '[:lower:]')"
                    echo
                    echo "Project  : utility"
                    echo "Task     : Repository clone - $disp"
                    echo "Repo Dir : $repo_dir"
                    echo "Repo URL : $repo_url"
                    if [ -n "$repo_branch" ]; then
                        echo "Branch   : $repo_branch"
                    fi
                    echo
                    case "$(prompt_menu_choice "1) Run  2) Cancel : ")" in
                        1)
                            launch_task "utility" "repo_clone" "$repo_id" "$repo_dir" \
                                "REPO_DISPLAY" "$disp" \
                                "REPO_URL" "$repo_url" \
                                "REPO_BRANCH" "$repo_branch"
                            return 0
                            ;;
                        *)
                            ;;
                    esac
                fi
                ;;
        esac
    done
}

utility_menu() {
    while true; do
        print_main_header
        echo "[Utility]"
        echo "1) Repository Clone"
        echo "2) Repo Hash Check"
        echo "3) Show Workspace Paths"
        echo "4) Back"
        echo

        case "$(prompt_dashboard_choice "Select: ")" in
            1)
                repository_clone_menu
                ;;
            2)
                case "$(prompt_menu_choice "1) Run  2) Cancel : ")" in
                    1)
                        launch_task "utility" "repo_hash_check" "default" ""
                        return 0
                        ;;
                    *)
                        ;;
                esac
                ;;
            3)
                echo
                echo "WORK_ROOT : $WORK_ROOT"
                echo "REPO_ROOT : $REPO_ROOT"
                echo "LOG_ROOT  : $LOG_ROOT"
                echo "TMP_ROOT  : $TMP_ROOT"
                echo
                pause_enter
                ;;
            4)
                return 0
                ;;
            __REFRESH__)
                ;;
            *)
                ;;
        esac
    done
}

main_menu() {
    init_workspace
    while true; do
        print_main_header
        echo "1) OpenWRT"
        echo "2) LinuxOS"
        echo "3) Zephyros"
        echo "4) Release Note"
        echo "5) Utility"
        echo "6) Exit Manager"
        echo

        case "$(prompt_dashboard_choice "Select: ")" in
            1)
                openwrt_menu
                ;;
            2)
                linuxos_menu
                ;;
            3)
                zephyros_menu
                ;;
            4)
                release_note_menu
                ;;
            5)
                utility_menu
                ;;
            6)
                echo
                echo "Running task가 있더라도 빌드는 계속 진행됩니다."
                echo "Exit Manager는 메뉴만 종료합니다."
                echo
                case "$(prompt_menu_choice "1) Exit Manager  2) Cancel : ")" in
                    1)
                        exit 0
                        ;;
                    *)
                        ;;
                esac
                ;;
            __REFRESH__)
                ;;
            *)
                ;;
        esac
    done
}

case "${1:-}" in
    __run_task)
        run_task_by_id "$2"
        ;;
    *)
        main_menu
        ;;
esac
