cat bin/daily-hash.sh
#!/usr/bin/env bash

CACHE_DIR="$HOME/.cache/geohashing"
STAMP="$CACHE_DIR/last_run"

mkdir -p "$CACHE_DIR"

LAT=43.66447305427876
LON=-79.39243007670768

TODAY=$(date +%F)
YESTERDAY=$(date -d yesterday +%F 2>/dev/null || date -v-1d +%F)

#
# Determine whether today's DJIA exists.
#
if [[ $(date -u +%H) -lt 21 ]]; then
    djia_available=false
else
    djia_available=true
fi

#
# Determine which geohash date should be displayed.
#
if (( $(echo "$LON > -30" | bc -l) )); then
    # East of 30W.

    if djia_available; then
        # Today's DJIA exists, so today's geohashes are valid.
        HASH_DATE="$TODAY"
    else
        # DJIA not published yet.
        # Continue using yesterday's geohashes.
        HASH_DATE="$YESTERDAY"
    fi
else
    # West of 30W always uses local date.
    HASH_DATE="$TODAY"
fi

#
# Skip if already shown.
#
if [[ -f "$STAMP" ]] &&
   [[ "$(cat "$STAMP")" == "$HASH_DATE" ]]; then
    exit 0
fi

python3 \
    "$HOME/bin/geohashing.py" \
    "$LAT" \
    "$LON" \
    --closest \
    -d "$HASH_DATE"

echo "$HASH_DATE" > "$STAMP"
