#!/usr/bin/env bash
# Scrape restaurants across Singapore using a grid of coordinates.
#
# By default runs in browser mode with high scroll depth (-depth 20) to
# maximize restaurant coverage per cell. Set FAST_MODE=1 to use the faster
# HTTP-only mode (capped at ~20 results per cell, but much quicker).
#
# Prerequisites:
#   1. Build the scraper: cd .. && make build
#   2. Generate coordinates: python3 generate_singapore_grid.py > sg_coords.csv
#
# Usage:
#   ./scrape_singapore.sh                    # browser mode, max coverage
#   FAST_MODE=1 ./scrape_singapore.sh        # fast HTTP mode (~20 results/cell)
#   DEPTH=30 ./scrape_singapore.sh           # deeper scrolling (browser mode)
#   DELAY=2 ./scrape_singapore.sh            # 2s delay between requests
#   SCRAPER=../bin/google_maps_scraper-rod ./scrape_singapore.sh  # use rod variant
#
# The script is resumable — it tracks completed coordinates in a progress log
# and skips them on restart.

set -euo pipefail

# --- Configuration ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRAPER="${SCRAPER:-${SCRIPT_DIR}/../bin/google_maps_scraper}"
COORDS_FILE="${COORDS_FILE:-${SCRIPT_DIR}/sg_coords.csv}"
OUTPUT_FILE="${OUTPUT_FILE:-${SCRIPT_DIR}/singapore_restaurants_raw.csv}"
PROGRESS_LOG="${PROGRESS_LOG:-${SCRIPT_DIR}/.scrape_progress.log}"
QUERY_FILE="${SCRIPT_DIR}/.query_restaurants.txt"
DELAY="${DELAY:-1}"          # seconds between requests
FAST_MODE="${FAST_MODE:-0}"  # set to 1 for fast HTTP-only mode
DEPTH="${DEPTH:-20}"         # scroll depth for browser mode (ignored in fast mode)

# --- Validation ---
if [[ ! -x "$SCRAPER" ]]; then
    echo "ERROR: Scraper binary not found or not executable at: $SCRAPER"
    echo "Build it first:  cd '${SCRIPT_DIR}/..' && make build"
    exit 1
fi

if [[ ! -f "$COORDS_FILE" ]]; then
    echo "ERROR: Coordinates file not found: $COORDS_FILE"
    echo "Generate it first:  python3 generate_singapore_grid.py > sg_coords.csv"
    exit 1
fi

# Create query file
echo "restaurants" > "$QUERY_FILE"

# Initialize output CSV with header if it doesn't exist
if [[ ! -f "$OUTPUT_FILE" ]]; then
    # Run a dummy scrape to get the CSV header, or write it manually
    echo "input_id,link,title,category,address,open_hours,popular_times,website,phone,plus_code,review_count,review_rating,reviews_per_rating,latitude,longitude,cid,status,descriptions,reviews_link,thumbnail,timezone,price_range,data_id,place_id,images,reservations,order_online,menu,owner,complete_address,about,user_reviews,user_reviews_extended,emails" > "$OUTPUT_FILE"
    echo "Initialized output file: $OUTPUT_FILE"
fi

# Initialize progress log
touch "$PROGRESS_LOG"

# --- Count totals ---
TOTAL_COORDS=$(wc -l < "$COORDS_FILE" | tr -d ' ')
COMPLETED=$(wc -l < "$PROGRESS_LOG" | tr -d ' ')
REMAINING=$((TOTAL_COORDS - COMPLETED))

echo "=== Singapore Restaurant Scraper ==="
if [[ "$FAST_MODE" == "1" ]]; then
    echo "Mode: FAST (HTTP-only, ~20 results/cell)"
else
    echo "Mode: BROWSER (depth=$DEPTH, max coverage)"
fi
echo "Total coordinates: $TOTAL_COORDS"
echo "Already completed: $COMPLETED"
echo "Remaining: $REMAINING"
echo "Delay between requests: ${DELAY}s"
echo "Output: $OUTPUT_FILE"
echo "===================================="
echo ""

if [[ "$REMAINING" -le 0 ]]; then
    echo "All coordinates already scraped! Run dedup_results.py to finalize."
    exit 0
fi

# --- Scraping loop ---
SCRAPED=0
ERRORS=0
START_TIME=$(date +%s)
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE" "$QUERY_FILE"' EXIT

while IFS= read -r coord; do
    # Skip already-completed coordinates
    if grep -qxF "$coord" "$PROGRESS_LOG" 2>/dev/null; then
        continue
    fi

    SCRAPED=$((SCRAPED + 1))
    DONE=$((COMPLETED + SCRAPED))

    # Progress display
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    if [[ "$ELAPSED" -gt 0 && "$SCRAPED" -gt 1 ]]; then
        RATE=$(echo "scale=2; $SCRAPED / $ELAPSED" | bc 2>/dev/null || echo "?")
        if [[ "$RATE" != "?" && "$RATE" != "0" && "$RATE" != ".0" && "$RATE" != "0.00" && "$RATE" != ".00" ]]; then
            ETA_SECS=$(echo "scale=0; ($TOTAL_COORDS - $DONE) / $RATE" | bc 2>/dev/null || echo "?")
            if [[ "$ETA_SECS" != "?" ]]; then
                ETA_H=$((ETA_SECS / 3600))
                ETA_M=$(( (ETA_SECS % 3600) / 60 ))
                ETA_STR="${ETA_H}h${ETA_M}m"
            else
                ETA_STR="?"
            fi
        else
            ETA_STR="calculating..."
        fi
    else
        RATE="?"
        ETA_STR="calculating..."
    fi

    printf "\r[%d/%d] Scraping %s (%s cells/s, ETA: %s, errors: %d)   " \
        "$DONE" "$TOTAL_COORDS" "$coord" "${RATE}" "$ETA_STR" "$ERRORS"

    # Build scraper flags
    SCRAPER_ARGS=(
        -geo "$coord"
        -zoom 18
        -lang en
        -c 1
        -input "$QUERY_FILE"
        -results "$TMPFILE"
    )

    if [[ "$FAST_MODE" == "1" ]]; then
        SCRAPER_ARGS+=(-fast-mode -radius 150 -exit-on-inactivity 30s)
    else
        SCRAPER_ARGS+=(-depth "$DEPTH" -exit-on-inactivity 3m)
    fi

    # Run scraper for this cell (retry up to MAX_RETRIES times on failure)
    MAX_RETRIES="${MAX_RETRIES:-3}"
    SUCCESS=0
    for ATTEMPT in $(seq 1 "$MAX_RETRIES"); do
        if "$SCRAPER" "${SCRAPER_ARGS[@]}" 2>>"${SCRIPT_DIR}/scraper_errors.log"; then
            SUCCESS=1
            break
        else
            echo "" >> "${SCRIPT_DIR}/scraper_errors.log"
            echo "=== RETRY $ATTEMPT/$MAX_RETRIES for $coord ===" >> "${SCRIPT_DIR}/scraper_errors.log"
            sleep 2
            > "$TMPFILE"
        fi
    done

    if [[ "$SUCCESS" == "1" ]]; then
        # Append results (skip CSV header line) to master file
        if [[ -f "$TMPFILE" && -s "$TMPFILE" ]]; then
            tail -n +2 "$TMPFILE" >> "$OUTPUT_FILE"
        fi
    else
        ERRORS=$((ERRORS + 1))
    fi

    # Mark coordinate as completed
    echo "$coord" >> "$PROGRESS_LOG"

    # Clean up temp file for next iteration
    > "$TMPFILE"

    # Rate limiting delay
    sleep "$DELAY"

done < "$COORDS_FILE"

echo ""
echo ""
echo "=== Scraping Complete ==="
TOTAL_ROWS=$(( $(wc -l < "$OUTPUT_FILE" | tr -d ' ') - 1 ))
echo "Total rows collected: $TOTAL_ROWS"
echo "Errors encountered: $ERRORS"
echo "Output file: $OUTPUT_FILE"
echo ""
echo "Next step: python3 dedup_results.py $OUTPUT_FILE singapore_restaurants.csv"
