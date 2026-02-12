#!/usr/bin/env python3
"""Generate a grid of lat/lon coordinates covering Singapore's land area.

Uses a simplified polygon boundary of Singapore (main island, Sentosa, Jurong Island)
and filters out ocean points using ray-casting. Outputs one "lat,lon" pair per line.

Usage:
    python3 generate_singapore_grid.py              # output coordinates to stdout
    python3 generate_singapore_grid.py --count       # show stats only
    python3 generate_singapore_grid.py --spacing 300 # custom spacing in meters
"""

import argparse
import math
import sys

# Simplified polygon boundaries for Singapore's land masses.
# Each polygon is a list of (lat, lon) vertices.

SINGAPORE_MAIN = [
    (1.160, 103.600), (1.160, 104.050), (1.470, 104.050), (1.470, 103.600),
]

# More detailed polygon to exclude ocean. This traces the rough coastline.
# We use multiple polygons: main island + major islands.

MAIN_ISLAND = [
    # Southwest coast (Tuas)
    (1.250, 103.618),
    (1.265, 103.600),
    (1.290, 103.601),
    (1.310, 103.620),
    (1.320, 103.642),
    # Northwest coast (Lim Chu Kang, Kranji)
    (1.355, 103.650),
    (1.385, 103.680),
    (1.415, 103.720),
    (1.430, 103.740),
    (1.445, 103.760),
    (1.450, 103.780),
    # North coast (Woodlands, Sembawang, Yishun)
    (1.455, 103.800),
    (1.460, 103.830),
    (1.465, 103.860),
    (1.460, 103.880),
    (1.455, 103.900),
    (1.450, 103.920),
    # Northeast coast (Punggol, Pasir Ris)
    (1.420, 103.950),
    (1.400, 103.970),
    (1.385, 103.985),
    (1.370, 104.000),
    (1.360, 104.020),
    (1.345, 104.040),
    (1.330, 104.050),
    # East coast (Changi, East Coast)
    (1.310, 104.050),
    (1.300, 104.035),
    (1.290, 103.990),
    (1.280, 103.950),
    # South coast (Marina, Sentosa approach)
    (1.270, 103.910),
    (1.265, 103.870),
    (1.260, 103.830),
    (1.265, 103.800),
    (1.270, 103.770),
    # Southwest (Jurong, Clementi)
    (1.275, 103.740),
    (1.270, 103.710),
    (1.260, 103.680),
    (1.255, 103.650),
    (1.250, 103.618),
]

SENTOSA = [
    (1.240, 103.825),
    (1.240, 103.860),
    (1.252, 103.860),
    (1.252, 103.825),
]

JURONG_ISLAND = [
    (1.255, 103.660),
    (1.255, 103.720),
    (1.280, 103.720),
    (1.280, 103.660),
]

# Pulau Ubin
PULAU_UBIN = [
    (1.395, 103.955),
    (1.395, 103.990),
    (1.420, 103.990),
    (1.420, 103.955),
]

# Pulau Tekong
PULAU_TEKONG = [
    (1.380, 104.010),
    (1.380, 104.060),
    (1.420, 104.060),
    (1.420, 104.010),
]

POLYGONS = [MAIN_ISLAND, SENTOSA, JURONG_ISLAND, PULAU_UBIN, PULAU_TEKONG]


def point_in_polygon(lat, lon, polygon):
    """Ray-casting algorithm to test if a point is inside a polygon."""
    n = len(polygon)
    inside = False
    j = n - 1
    for i in range(n):
        yi, xi = polygon[i]
        yj, xj = polygon[j]
        if ((yi > lat) != (yj > lat)) and (lon < (xj - xi) * (lat - yi) / (yj - yi) + xi):
            inside = not inside
        j = i
    return inside


def point_in_any_polygon(lat, lon, polygons):
    """Check if point falls inside any of the given polygons."""
    for poly in polygons:
        if point_in_polygon(lat, lon, poly):
            return True
    return False


def generate_grid(spacing_m=250):
    """Generate grid coordinates covering Singapore's land area.

    Args:
        spacing_m: Grid spacing in meters (default 250m for 150m radius overlap).

    Returns:
        List of (lat, lon) tuples on land.
    """
    # Convert meters to degrees at Singapore's latitude (~1.3N)
    # 1 degree latitude ≈ 111,320 meters
    # 1 degree longitude ≈ 111,320 * cos(lat) meters
    lat_center = 1.35
    lat_step = spacing_m / 111320.0
    lon_step = spacing_m / (111320.0 * math.cos(math.radians(lat_center)))

    # Bounding box for Singapore
    lat_min, lat_max = 1.20, 1.47
    lon_min, lon_max = 103.59, 104.07

    points = []
    lat = lat_min
    while lat <= lat_max:
        lon = lon_min
        while lon <= lon_max:
            if point_in_any_polygon(lat, lon, POLYGONS):
                points.append((round(lat, 6), round(lon, 6)))
            lon += lon_step
        lat += lat_step

    return points


def main():
    parser = argparse.ArgumentParser(description="Generate Singapore grid coordinates")
    parser.add_argument("--count", action="store_true", help="Show stats without generating output")
    parser.add_argument("--spacing", type=int, default=250, help="Grid spacing in meters (default: 250)")
    args = parser.parse_args()

    points = generate_grid(spacing_m=args.spacing)

    if args.count:
        lats = [p[0] for p in points]
        lons = [p[1] for p in points]
        print(f"Grid spacing: {args.spacing}m")
        print(f"Total land points: {len(points)}")
        print(f"Latitude range: {min(lats):.6f} to {max(lats):.6f}")
        print(f"Longitude range: {min(lons):.6f} to {max(lons):.6f}")
        est_hours_low = len(points) * 2 / 3600
        est_hours_high = len(points) * 4 / 3600
        print(f"Estimated scrape time: {est_hours_low:.1f} - {est_hours_high:.1f} hours (at 2-4s per cell)")
    else:
        for lat, lon in points:
            print(f"{lat},{lon}")


if __name__ == "__main__":
    main()
