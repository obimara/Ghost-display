#!/usr/bin/env bash
# lib/logging.sh - Unified logging system for Ghost Display
# Provides log(), logd(), logi(), logw(), loge() functions

set -euo pipefail

# Initialize logging if not already done
init_logging() {
    LOG_TAG="${LOG_TAG:-ghost-display}"
    LOG_LEVEL="${LOG_LEVEL:-info}"
    LOG_FILE="${LOG_FILE:-}"
    
    # Log level priorities
    declare -gA _LL=([debug]=0 [info]=1 [warn]=2 [error]=3)
    declare -g _min_ll="${_LL[${LOG_LEVEL:-info}]:-1}"
}

# Main log function
log() {
    local lv="${1:-info}"; shift
    local msg="$*"
    
    # Check if we should log this level
    (( ${_LL[$lv]:-1} < _min_ll )) && return 0 || true
    
    local ts
    ts="$(date '+%F %T')"
    local line="$ts [${LOG_TAG}][${lv}] $msg"
    
    # Log to syslog/journald
    logger -t "${LOG_TAG}" -- "[${lv}] $msg" 2>/dev/null || true
    
    # Log to stdout
    echo "$line"
    
    # Log to file if configured
    [[ -n "$LOG_FILE" ]] && echo "$line" >> "$LOG_FILE" || true
}

# Convenience functions
logd() { log debug "$*"; }
logi() { log info "$*"; }
logw() { log warn "$*"; }
loge() { log error "$*"; }

# Initialize logging on source
init_logging
