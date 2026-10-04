#!/usr/bin/env bash
# Shared profile parser for the unified daemon and the X11-only launcher.
# Input: VIRTUAL_* settings. Output: MONITOR_* arrays and FRAMEBUFFER_* dimensions.
# The caller provides loge(); this module never starts a service or changes X11.

is_positive_int() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_positive_number() {
    [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ && "$1" =~ [1-9] ]]
}

build_monitor_specs() {
    local spec resolution scale width height dimensions mm_width mm_height
    local x=0 y=0 index=1 limit
    local -a specs=()

    if ! is_positive_int "$VIRTUAL_MONITORS" || (( ${#VIRTUAL_MONITORS} > 2 )) || (( VIRTUAL_MONITORS > 64 )); then
        loge "VIRTUAL_MONITORS must be between 1 and 64."
        return 1
    fi
    if ! is_positive_number "$VIRTUAL_SCALE"; then
        loge "VIRTUAL_SCALE must be a positive number."
        return 1
    fi
    if ! is_positive_number "$VIRTUAL_DPI" || ! awk -v dpi="$VIRTUAL_DPI" 'BEGIN { exit !(dpi >= 1 && dpi <= 10000) }'; then
        loge "VIRTUAL_DPI must be between 1 and 10000."
        return 1
    fi
    if [[ "$VIRTUAL_LAYOUT" != horizontal && "$VIRTUAL_LAYOUT" != vertical ]]; then
        loge "VIRTUAL_LAYOUT must be horizontal or vertical."
        return 1
    fi
    for limit in "$VIRTUAL_MAX_WIDTH" "$VIRTUAL_MAX_HEIGHT"; do
        if ! is_positive_int "$limit" || (( ${#limit} > 5 )) || (( limit > 32767 )); then
            loge "Framebuffer limits must be between 1 and 32767."
            return 1
        fi
    done

    if [[ -n "$VIRTUAL_MONITOR_SPECS" ]]; then
        if [[ "$VIRTUAL_MONITOR_SPECS" == *, || "$VIRTUAL_MONITOR_SPECS" == *$'\n'* ]]; then
            loge "Empty or multiline monitor specification."
            return 1
        fi
        IFS=',' read -r -a specs <<<"$VIRTUAL_MONITOR_SPECS"
        if (( ${#specs[@]} > 64 )); then
            loge "At most 64 virtual monitors are supported."
            return 1
        fi
    else
        for ((index = 0; index < VIRTUAL_MONITORS; index++)); do
            specs+=("${VIRTUAL_RESOLUTION}@${VIRTUAL_SCALE}")
        done
    fi

    MONITOR_NAMES=() MONITOR_WIDTHS=() MONITOR_HEIGHTS=()
    MONITOR_MM_WIDTHS=() MONITOR_MM_HEIGHTS=() MONITOR_X=() MONITOR_Y=()
    FRAMEBUFFER_WIDTH=0 FRAMEBUFFER_HEIGHT=0
    index=1

    for spec in "${specs[@]}"; do
        spec="${spec//[[:space:]]/}"
        resolution="${spec%@*}"
        scale="$VIRTUAL_SCALE"
        [[ "$spec" != *@* ]] || scale="${spec##*@}"
        if [[ ! "$resolution" =~ ^([1-9][0-9]*)x([1-9][0-9]*)$ ]]; then
            loge "Invalid resolution '$resolution'. Use WIDTHxHEIGHT."
            return 1
        fi
        width="${BASH_REMATCH[1]}" height="${BASH_REMATCH[2]}"
        if ! is_positive_number "$scale"; then
            loge "Invalid scale '$scale' in VIRTUAL_MONITOR_SPECS."
            return 1
        fi
        # Calculate pixels and physical dimensions together: one awk per monitor.
        if ! dimensions=$(awk -v w="$width" -v h="$height" -v s="$scale" -v dpi="$VIRTUAL_DPI" 'BEGIN {
            w = int(w * s + 0.5); h = int(h * s + 0.5)
            if (!(w >= 1 && w <= 32767 && h >= 1 && h <= 32767)) exit 1
            mw = int(w * 25.4 / dpi + 0.5); mh = int(h * 25.4 / dpi + 0.5)
            printf "%d %d %d %d", w, h, (mw < 1 ? 1 : mw), (mh < 1 ? 1 : mh)
        }'); then
            loge "Scaled monitor dimensions must be between 1 and 32767 pixels."
            return 1
        fi
        read -r width height mm_width mm_height <<<"$dimensions"
        MONITOR_NAMES+=("${VIRTUAL_NAME_PREFIX}-${index}")
        MONITOR_WIDTHS+=("$width") MONITOR_HEIGHTS+=("$height")
        MONITOR_MM_WIDTHS+=("$mm_width") MONITOR_MM_HEIGHTS+=("$mm_height")
        MONITOR_X+=("$x") MONITOR_Y+=("$y")
        (( x + width <= FRAMEBUFFER_WIDTH )) || FRAMEBUFFER_WIDTH=$((x + width))
        (( y + height <= FRAMEBUFFER_HEIGHT )) || FRAMEBUFFER_HEIGHT=$((y + height))
        if (( FRAMEBUFFER_WIDTH > VIRTUAL_MAX_WIDTH || FRAMEBUFFER_HEIGHT > VIRTUAL_MAX_HEIGHT )); then
            loge "Requested framebuffer ${FRAMEBUFFER_WIDTH}x${FRAMEBUFFER_HEIGHT} exceeds ${VIRTUAL_MAX_WIDTH}x${VIRTUAL_MAX_HEIGHT}."
            return 1
        fi
        if [[ "$VIRTUAL_LAYOUT" == horizontal ]]; then
            x=$((x + width))
        else
            y=$((y + height))
        fi
        index=$((index + 1))
    done
}
