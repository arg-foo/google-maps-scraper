# Singapore Restaurant Scraper — Windows Setup Guide

This guide covers running the Singapore restaurant scraper on Windows using Docker and PowerShell. No local Go build or Playwright installation is required.

## Prerequisites

### 1. Docker Desktop for Windows

- Download from https://www.docker.com/products/docker-desktop/
- During installation, enable the **WSL 2 backend** (recommended)
- After install, open Docker Desktop and wait for it to show "Docker is running"
- Verify in PowerShell:
  ```powershell
  docker --version
  ```

### 2. Python 3

- Download from https://www.python.org/downloads/
- During installation, check **"Add Python to PATH"**
- Verify in PowerShell:
  ```powershell
  python --version
  ```

### 3. Pull the Docker image (one-time)

```powershell
docker pull gosom/google-maps-scraper
```

### 4. Allow PowerShell script execution (one-time)

Run this once (as admin, or scoped to current user):

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

## Step-by-Step Workflow

```powershell
# 1. Clone the repo
git clone https://github.com/gosom/google-maps-scraper.git
cd google-maps-scraper\singapore

# 2. Generate the coordinate grid (if sg_coords.csv doesn't exist yet)
python generate_singapore_grid.py > sg_coords.csv

# 3. Run the scraper (browser mode — slow but thorough, max coverage)
.\scrape_singapore.ps1

# 4. After scraping completes, deduplicate results
python dedup_results.py singapore_restaurants_raw.csv singapore_restaurants.csv
```

## Usage Options

```powershell
# Fast mode (~20 results per cell, much quicker)
.\scrape_singapore.ps1 -FastMode

# Custom scroll depth and delay
.\scrape_singapore.ps1 -Depth 30 -Delay 2

# Use a specific Docker image tag
.\scrape_singapore.ps1 -DockerImage "gosom/google-maps-scraper:latest-rod"

# Custom coordinate file and output
.\scrape_singapore.ps1 -CoordsFile my_coords.csv -OutputFile my_output.csv
```

### All Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-CoordsFile` | `sg_coords.csv` | Path to the coordinate grid CSV |
| `-OutputFile` | `singapore_restaurants_raw.csv` | Path for combined raw results |
| `-ProgressLog` | `.scrape_progress.log` | Progress tracking file |
| `-DockerImage` | `gosom/google-maps-scraper` | Docker image to use |
| `-Delay` | `1` | Seconds between requests |
| `-Depth` | `20` | Scroll depth in browser mode |
| `-MaxRetries` | `3` | Retry attempts per coordinate |
| `-FastMode` | off | Use fast HTTP-only mode |

## Resuming After Interruption

The script tracks completed coordinates in `.scrape_progress.log`. If the scraper is interrupted (Ctrl+C, crash, etc.), simply re-run the same command and it will skip already-completed coordinates:

```powershell
# Just re-run — completed cells are automatically skipped
.\scrape_singapore.ps1
```

## Testing with a Small Subset

Before running the full grid, test with a few coordinates:

```powershell
Get-Content sg_coords.csv | Select-Object -First 3 | Set-Content test_coords.csv
.\scrape_singapore.ps1 -CoordsFile test_coords.csv -OutputFile test_output.csv
```

## Troubleshooting

### "Docker is not installed or not in PATH"

Install Docker Desktop and restart PowerShell.

### "Docker daemon is not running"

Open the Docker Desktop application and wait for it to fully start.

### Script won't run / "running scripts is disabled"

Run the execution policy command:
```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

### Slow performance

- The Docker image downloads Chromium on first run; subsequent runs are faster.
- Use `-FastMode` for quicker results with less coverage per cell.
- Increase Docker memory: Docker Desktop > Settings > Resources (4GB+ recommended).

### Out of memory

Docker Desktop defaults to limited RAM. Go to **Docker Desktop > Settings > Resources** and increase the memory allocation.

## How It Works

The PowerShell script (`scrape_singapore.ps1`) is the Windows equivalent of `scrape_singapore.sh`. Instead of running a locally built Go binary, it runs the `gosom/google-maps-scraper` Docker container for each coordinate cell. The Docker image bundles all Playwright/Chromium dependencies, so nothing needs to be installed beyond Docker itself.

The workflow is:

1. For each coordinate in `sg_coords.csv`, run a Docker container that scrapes Google Maps for "restaurants" near that location
2. Collect results into `singapore_restaurants_raw.csv`
3. Deduplicate with `dedup_results.py` to produce the final `singapore_restaurants.csv`
