#!/usr/bin/env bash
#=============================================================================
# CI-OS AI Setup
#
# Hardware benchmark, Ollama model recommendation, and model install helper.
#
# Installed command names:
#   ci-os-benchmark
#   ci-os-model-recommend
#   ci-os-model-install
#
# Direct usage:
#   ./scripts/ci-os-ai-setup.sh benchmark
#   ./scripts/ci-os-ai-setup.sh recommend
#   ./scripts/ci-os-ai-setup.sh install --yes
#=============================================================================

set -euo pipefail

APP_NAME="$(basename "$0")"
COMMAND="${1:-}"

case "$APP_NAME" in
    ci-os-benchmark) COMMAND="benchmark" ;;
    ci-os-model-recommend) COMMAND="recommend" ;;
    ci-os-model-install) COMMAND="install" ;;
esac

if [[ "$APP_NAME" == "ci-os-ai-setup.sh" || "$APP_NAME" == "ci-os-ai-setup" ]]; then
    shift || true
else
    # Command was inferred from executable name, so all args are command args.
    COMMAND="${COMMAND:-help}"
fi

if [[ -z "$COMMAND" ]]; then
    COMMAND="help"
fi

if [[ "$(id -u)" -eq 0 ]]; then
    DATA_DIR="${CI_OS_DATA_DIR:-/var/lib/ci-os}"
else
    DATA_DIR="${CI_OS_DATA_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ci-os}"
fi

BENCHMARK_JSON="$DATA_DIR/benchmark.json"
RECOMMENDATIONS_JSON="$DATA_DIR/model-recommendations.json"
LOG_FILE="${CI_OS_AI_SETUP_LOG:-/var/log/ci-os-ai-setup.log}"

mkdir -p "$DATA_DIR"
if [[ "$(id -u)" -eq 0 ]]; then
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="$DATA_DIR/ci-os-ai-setup.log"
else
    LOG_FILE="$DATA_DIR/ci-os-ai-setup.log"
fi

log() {
    printf '[CI-OS] %s\n' "$*" | tee -a "$LOG_FILE" >&2
}

json_escape() {
    local value="${1:-}"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/ }"
    value="${value//$'\r'/ }"
    printf '%s' "$value"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

read_mem_gb() {
    awk '/MemTotal:/ { printf "%.0f\n", ($2 / 1024 / 1024) }' /proc/meminfo 2>/dev/null || echo 0
}

read_cpu_model() {
    awk -F: '/model name/ { sub(/^[ \t]+/, "", $2); print $2; exit }' /proc/cpuinfo 2>/dev/null || echo "unknown"
}

read_cpu_cores() {
    nproc 2>/dev/null || echo 1
}

read_root_disk_free_gb() {
    df -Pk / 2>/dev/null | awk 'NR==2 { printf "%.0f\n", ($4 / 1024 / 1024) }' || echo 0
}

read_gpu_summary() {
    if command_exists lspci; then
        lspci | awk 'tolower($0) ~ /(vga|3d|display)/ {print}' | paste -sd '; ' -
    else
        echo ""
    fi
}

detect_gpu_vendor() {
    local gpu_summary="$1"
    local lower
    lower="$(printf '%s' "$gpu_summary" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lower" == *"amd"* || "$lower" == *"advanced micro devices"* || "$lower" == *"ati"* ]]; then
        echo "amd"
    elif [[ "$lower" == *"nvidia"* ]]; then
        echo "nvidia"
    elif [[ "$lower" == *"intel"* ]]; then
        echo "intel"
    else
        echo "none"
    fi
}

read_vram_gb() {
    if command_exists rocm-smi; then
        local mib
        mib="$(rocm-smi --showmeminfo vram --csv 2>/dev/null | awk -F, 'tolower($0) ~ /total.*vram/ {gsub(/[^0-9.]/, "", $NF); print $NF; exit}')"
        if [[ -n "${mib:-}" ]]; then
            awk -v mib="$mib" 'BEGIN { printf "%.0f\n", mib / 1024 }'
            return 0
        fi
    fi

    if command_exists nvidia-smi; then
        local mib
        mib="$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | awk 'NR==1 {print $1}')"
        if [[ -n "${mib:-}" ]]; then
            awk -v mib="$mib" 'BEGIN { printf "%.0f\n", mib / 1024 }'
            return 0
        fi
    fi

    echo 0
}

ollama_status() {
    if ! command_exists ollama; then
        echo "missing"
        return 0
    fi
    if ollama list >/dev/null 2>&1; then
        echo "running"
    else
        echo "installed_not_ready"
    fi
}

write_benchmark() {
    local mem_gb cpu_cores cpu_model disk_free_gb gpu_summary gpu_vendor vram_gb ollama_state created_at
    mem_gb="$(read_mem_gb)"
    cpu_cores="$(read_cpu_cores)"
    cpu_model="$(read_cpu_model)"
    disk_free_gb="$(read_root_disk_free_gb)"
    gpu_summary="$(read_gpu_summary)"
    gpu_vendor="$(detect_gpu_vendor "$gpu_summary")"
    vram_gb="$(read_vram_gb)"
    ollama_state="$(ollama_status)"
    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    cat > "$BENCHMARK_JSON" <<EOF
{
  "created_at": "$created_at",
  "hostname": "$(json_escape "$(hostname 2>/dev/null || echo unknown)")",
  "os_pretty_name": "$(json_escape "$(awk -F= '/^PRETTY_NAME=/ {gsub(/"/, "", $2); print $2}' /etc/os-release 2>/dev/null || echo unknown)")",
  "kernel": "$(json_escape "$(uname -r 2>/dev/null || echo unknown)")",
  "cpu_model": "$(json_escape "$cpu_model")",
  "cpu_cores": $cpu_cores,
  "memory_gb": $mem_gb,
  "root_disk_free_gb": $disk_free_gb,
  "gpu_vendor": "$(json_escape "$gpu_vendor")",
  "gpu_summary": "$(json_escape "$gpu_summary")",
  "vram_gb": $vram_gb,
  "ollama": "$(json_escape "$ollama_state")"
}
EOF

    log "Benchmark written to $BENCHMARK_JSON"
}

get_json_number() {
    local key="$1" file="$2"
    awk -F: -v key="\"$key\"" '$1 ~ key {gsub(/[, ]/, "", $2); print $2; exit}' "$file" 2>/dev/null
}

get_json_string() {
    local key="$1" file="$2"
    awk -F: -v key="\"$key\"" '$1 ~ key {sub(/^[ \t]*"/, "", $2); sub(/",?$/, "", $2); print $2; exit}' "$file" 2>/dev/null
}

models_json_array() {
    local first=1 model
    printf '['
    for model in "$@"; do
        if [[ "$first" -eq 0 ]]; then
            printf ', '
        fi
        first=0
        printf '"%s"' "$(json_escape "$model")"
    done
    printf ']'
}

recommend_models() {
    if [[ ! -f "$BENCHMARK_JSON" ]]; then
        write_benchmark >/dev/null
    fi

    local mem_gb disk_free_gb vram_gb gpu_vendor tier rationale created_at
    mem_gb="$(get_json_number memory_gb "$BENCHMARK_JSON")"
    disk_free_gb="$(get_json_number root_disk_free_gb "$BENCHMARK_JSON")"
    vram_gb="$(get_json_number vram_gb "$BENCHMARK_JSON")"
    gpu_vendor="$(get_json_string gpu_vendor "$BENCHMARK_JSON")"
    mem_gb="${mem_gb:-0}"
    disk_free_gb="${disk_free_gb:-0}"
    vram_gb="${vram_gb:-0}"
    gpu_vendor="${gpu_vendor:-none}"

    local -a essential=()
    local -a recommended=()
    local -a optional=()

    essential=("nomic-embed-text" "gemma3:1b")

    if (( mem_gb < 12 )); then
        tier="small"
        recommended=("qwen2.5:1.5b")
        optional=("llama3.2:3b")
        rationale="Low-memory profile. Keep defaults small and responsive."
    elif (( mem_gb < 24 )); then
        tier="balanced"
        recommended=("llama3.2:3b" "qwen2.5:3b")
        optional=("mistral:7b")
        rationale="Mid-memory profile. Prefer 3B models; 7B is optional."
    elif (( mem_gb < 48 )); then
        tier="workstation"
        recommended=("llama3.1:8b" "qwen2.5:7b")
        optional=("mistral:7b")
        rationale="Workstation profile. 7B/8B models should be comfortable."
    else
        tier="large"
        recommended=("llama3.1:8b" "qwen2.5:14b")
        optional=("qwen2.5:32b")
        rationale="Large-memory profile. Larger local models are possible."
    fi

    if [[ "$gpu_vendor" == "amd" && "$vram_gb" -ge 12 ]]; then
        optional+=("llava:7b")
        rationale="$rationale AMD GPU detected; validate ROCm before relying on GPU offload."
    elif [[ "$gpu_vendor" == "nvidia" && "$vram_gb" -ge 12 ]]; then
        optional+=("llava:7b")
        rationale="$rationale NVIDIA GPU detected; CUDA-backed Ollama may support GPU offload."
    fi

    if (( disk_free_gb < 20 )); then
        optional=()
        rationale="$rationale Disk headroom is tight; optional models suppressed."
    fi

    created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat > "$RECOMMENDATIONS_JSON" <<EOF
{
  "created_at": "$created_at",
  "benchmark_file": "$(json_escape "$BENCHMARK_JSON")",
  "tier": "$(json_escape "$tier")",
  "rationale": "$(json_escape "$rationale")",
  "install_by_default": $(models_json_array "${essential[@]}" "${recommended[@]}"),
  "essential": $(models_json_array "${essential[@]}"),
  "recommended": $(models_json_array "${recommended[@]}"),
  "optional": $(models_json_array "${optional[@]}")
}
EOF

    log "Recommendations written to $RECOMMENDATIONS_JSON"
}

print_summary() {
    if [[ -f "$BENCHMARK_JSON" ]]; then
        echo "Benchmark: $BENCHMARK_JSON"
        echo "  CPU: $(get_json_string cpu_model "$BENCHMARK_JSON")"
        echo "  Cores: $(get_json_number cpu_cores "$BENCHMARK_JSON")"
        echo "  RAM: $(get_json_number memory_gb "$BENCHMARK_JSON") GB"
        echo "  Root free: $(get_json_number root_disk_free_gb "$BENCHMARK_JSON") GB"
        echo "  GPU: $(get_json_string gpu_vendor "$BENCHMARK_JSON") ($(get_json_number vram_gb "$BENCHMARK_JSON") GB VRAM reported)"
        echo "  Ollama: $(get_json_string ollama "$BENCHMARK_JSON")"
    fi

    if [[ -f "$RECOMMENDATIONS_JSON" ]]; then
        echo "Recommendations: $RECOMMENDATIONS_JSON"
        echo "  Tier: $(get_json_string tier "$RECOMMENDATIONS_JSON")"
        echo "  Rationale: $(get_json_string rationale "$RECOMMENDATIONS_JSON")"
        echo "  Default install: $(sed -n 's/^[[:space:]]*"install_by_default":[[:space:]]*//p' "$RECOMMENDATIONS_JSON")"
    fi
}

extract_default_models() {
    awk '/"install_by_default"/ {
        line=$0
        sub(/^.*\[/, "", line)
        sub(/\].*$/, "", line)
        gsub(/"/, "", line)
        gsub(/,/, " ", line)
        print line
    }' "$RECOMMENDATIONS_JSON"
}

ensure_ollama_ready() {
    if ! command_exists ollama; then
        log "Ollama is not installed; cannot install models yet."
        return 1
    fi
    if ollama list >/dev/null 2>&1; then
        return 0
    fi
    if command_exists systemctl && systemctl cat ollama.service >/dev/null 2>&1; then
        systemctl start ollama.service 2>/dev/null || true
        sleep 5
    fi
    if ollama list >/dev/null 2>&1; then
        return 0
    fi
    log "Ollama is installed but not ready; start it with: systemctl start ollama"
    return 1
}

install_models() {
    local assume_yes=0 dry_run=0 include_optional=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes|-y) assume_yes=1; shift ;;
            --dry-run) dry_run=1; shift ;;
            --include-optional) include_optional=1; shift ;;
            *) log "Unknown install option: $1"; return 2 ;;
        esac
    done

    recommend_models >/dev/null
    local models
    models="$(extract_default_models)"

    if [[ "$include_optional" -eq 1 ]]; then
        local optional
        optional="$(awk '/"optional"/ {line=$0; sub(/^.*\[/, "", line); sub(/\].*$/, "", line); gsub(/"/, "", line); gsub(/,/, " ", line); print line}' "$RECOMMENDATIONS_JSON")"
        models="$models $optional"
    fi

    echo "Models selected: $models"
    if [[ "$dry_run" -eq 1 ]]; then
        return 0
    fi

    if [[ "$assume_yes" -ne 1 ]]; then
        read -r -p "Pull these Ollama models now? [y/N] " reply
        case "$reply" in
            y|Y|yes|YES) ;;
            *) log "Model install skipped."; return 0 ;;
        esac
    fi

    ensure_ollama_ready || return 1

    local model
    for model in $models; do
        if [[ -z "$model" ]]; then
            continue
        fi
        if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$model"; then
            log "$model already installed"
            continue
        fi
        log "Pulling $model"
        ollama pull "$model" || log "Warning: failed to pull $model"
    done
}

usage() {
    cat <<'EOF'
Usage:
  ci-os-benchmark [--json]
  ci-os-model-recommend [--json]
  ci-os-model-install [--yes] [--dry-run] [--include-optional]
  ci-os-ai-setup.sh benchmark|recommend|install [options]

Files:
  benchmark.json and model-recommendations.json are written under /var/lib/ci-os
  when run as root, otherwise under ~/.local/state/ci-os.
EOF
}

case "$COMMAND" in
    benchmark)
        write_benchmark
        if [[ "${1:-}" == "--json" ]]; then
            cat "$BENCHMARK_JSON"
        else
            print_summary
        fi
        ;;
    recommend)
        recommend_models
        if [[ "${1:-}" == "--json" ]]; then
            cat "$RECOMMENDATIONS_JSON"
        else
            print_summary
        fi
        ;;
    install)
        install_models "$@"
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        log "Unknown command: $COMMAND"
        usage
        exit 2
        ;;
esac
