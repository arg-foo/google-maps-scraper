#!/usr/bin/env python3
"""Deduplicate scraped restaurant results by data_id or composite key.

Reads the raw CSV output from scrape_singapore.sh and removes duplicate rows.
Primary dedup key: data_id (Google's internal ID, populated in fast mode).
Fallback key: title + latitude + longitude (for rows where data_id is empty).

Usage:
    python3 dedup_results.py singapore_restaurants_raw.csv singapore_restaurants.csv
    python3 dedup_results.py input.csv output.csv --stats-only
"""

import argparse
import csv
import sys


def dedup(input_path, output_path=None, stats_only=False):
    seen = set()
    rows_total = 0
    rows_kept = 0
    rows_dup = 0
    rows_no_key = 0

    kept_rows = []
    header = None

    with open(input_path, newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        header = reader.fieldnames

        if not header:
            print("ERROR: CSV file has no header row.", file=sys.stderr)
            sys.exit(1)

        for row in reader:
            rows_total += 1

            # Primary key: data_id
            data_id = row.get("data_id", "").strip()
            if data_id:
                key = f"did:{data_id}"
            else:
                # Fallback: title + lat + lon
                title = row.get("title", "").strip()
                lat = row.get("latitude", "").strip()
                lon = row.get("longitude", "").strip()
                if title and lat and lon:
                    key = f"tloc:{title}|{lat}|{lon}"
                else:
                    rows_no_key += 1
                    continue

            if key in seen:
                rows_dup += 1
                continue

            seen.add(key)
            rows_kept += 1
            if not stats_only:
                kept_rows.append(row)

    # Write output
    if not stats_only and output_path:
        with open(output_path, "w", newline="", encoding="utf-8") as f:
            writer = csv.DictWriter(f, fieldnames=header)
            writer.writeheader()
            writer.writerows(kept_rows)
        print(f"Written to: {output_path}")

    # Print stats
    print(f"\n=== Deduplication Stats ===")
    print(f"Total rows read:     {rows_total:,}")
    print(f"Unique rows kept:    {rows_kept:,}")
    print(f"Duplicates removed:  {rows_dup:,}")
    if rows_no_key > 0:
        print(f"Rows with no key:    {rows_no_key:,} (skipped — no data_id or title+lat+lon)")
    print(f"Dedup rate:          {rows_dup / rows_total * 100:.1f}%" if rows_total > 0 else "N/A")


def main():
    parser = argparse.ArgumentParser(description="Deduplicate restaurant CSV results")
    parser.add_argument("input", help="Input CSV file (raw scrape output)")
    parser.add_argument("output", nargs="?", help="Output CSV file (deduplicated)")
    parser.add_argument("--stats-only", action="store_true", help="Show stats without writing output")
    args = parser.parse_args()

    if not args.output and not args.stats_only:
        print("ERROR: Provide an output file path or use --stats-only", file=sys.stderr)
        sys.exit(1)

    dedup(args.input, args.output, args.stats_only)


if __name__ == "__main__":
    main()
