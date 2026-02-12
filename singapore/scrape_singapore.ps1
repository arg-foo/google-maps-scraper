#Requires -Version 5.1
<#
.SYNOPSIS
    Scrape restaurants across Singapore using a grid of coordinates via Docker.

.DESCRIPTION
    Windows equivalent of scrape_singapore.sh. Uses the gosom/google-maps-scraper
    Docker image instead of a local binary, so Playwright/Chromium dependencies are
    handled automatically.

    By default runs in browser mode with high scroll depth (-Depth 20) to maximize
    restaurant coverage per cell. Use -FastMode for the faster HTTP-only mode
    (capped at ~20 results per cell, but much quicker).

    The script is resumable — it tracks completed coordinates in a progress log
    and skips them on restart.

.PARAMETER CoordsFile
    Path to the coordinate grid CSV. Default: sg_coords.csv in the script directory.

.PARAMETER OutputFile
    Path for the combined raw results CSV. Default: singapore_restaurants_raw.csv
    in the script directory.

.PARAMETER ProgressLog
    Path to the progress tracking file. Default: .scrape_progress.log in the
    script directory.

.PARAMETER DockerImage
    Docker image to use. Default: gosom/google-maps-scraper

.PARAMETER Delay
    Seconds to wait between requests. Default: 1

.PARAMETER Depth
    Scroll depth for browser mode (ignored in fast mode). Default: 20

.PARAMETER MaxRetries
    Number of retry attempts per coordinate on failure. Default: 3

.PARAMETER FastMode
    Use fast HTTP-only mode (~20 results/cell) instead of browser mode.

.EXAMPLE
    .\scrape_singapore.ps1
    # Browser mode, max coverage

.EXAMPLE
    .\scrape_singapore.ps1 -FastMode
    # Fast HTTP mode (~20 results per cell)

.EXAMPLE
    .\scrape_singapore.ps1 -Depth 30 -Delay 2
    # Deeper scrolling with 2s delay
#>
[CmdletBinding()]
param(
    [string]$CoordsFile,
    [string]$OutputFile,
    [string]$ProgressLog,
    [string]$DockerImage = "gosom/google-maps-scraper",
    [int]$Delay = 1,
    [int]$Depth = 20,
    [int]$MaxRetries = 3,
    [switch]$FastMode
)

# --- Configuration ---
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

if (-not $CoordsFile) {
    $CoordsFile = Join-Path $ScriptDir "sg_coords.csv"
}
if (-not $OutputFile) {
    $OutputFile = Join-Path $ScriptDir "singapore_restaurants_raw.csv"
}
if (-not $ProgressLog) {
    $ProgressLog = Join-Path $ScriptDir ".scrape_progress.log"
}

$QueryFile = Join-Path $ScriptDir ".query_restaurants.txt"
$ErrorLog = Join-Path $ScriptDir "scraper_errors.log"

# --- Validation ---
$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if (-not $dockerCmd) {
    Write-Error "Docker is not installed or not in PATH. Install Docker Desktop for Windows first."
    exit 1
}

# Check Docker daemon is running
try {
    $null = & docker info 2>&1
    if ($LASTEXITCODE -ne 0) { throw }
} catch {
    Write-Error "Docker daemon is not running. Open Docker Desktop and wait for it to start."
    exit 1
}

if (-not (Test-Path $CoordsFile)) {
    Write-Error "Coordinates file not found: $CoordsFile`nGenerate it first: python generate_singapore_grid.py > sg_coords.csv"
    exit 1
}

# --- Initialization ---
# Create query file
[System.IO.File]::WriteAllText($QueryFile, "restaurants`n", [System.Text.UTF8Encoding]::new($false))

# CSV header
$CsvHeader = "input_id,link,title,category,address,open_hours,popular_times,website,phone,plus_code,review_count,review_rating,reviews_per_rating,latitude,longitude,cid,status,descriptions,reviews_link,thumbnail,timezone,price_range,data_id,place_id,images,reservations,order_online,menu,owner,complete_address,about,user_reviews,user_reviews_extended,emails"

# Initialize output CSV with header if it doesn't exist
if (-not (Test-Path $OutputFile)) {
    [System.IO.File]::WriteAllText($OutputFile, "$CsvHeader`n", [System.Text.UTF8Encoding]::new($false))
    Write-Host "Initialized output file: $OutputFile"
}

# Initialize progress log
if (-not (Test-Path $ProgressLog)) {
    New-Item -Path $ProgressLog -ItemType File -Force | Out-Null
}

# Load completed coordinates into a HashSet for O(1) lookups
$completedSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($line in [System.IO.File]::ReadAllLines($ProgressLog)) {
    if ($line.Trim()) {
        $null = $completedSet.Add($line.Trim())
    }
}

# Load coordinates
$allCoords = [System.IO.File]::ReadAllLines($CoordsFile) | Where-Object { $_.Trim() }
$totalCoords = $allCoords.Count
$completed = $completedSet.Count
$remaining = $totalCoords - $completed

# --- Status ---
Write-Host "=== Singapore Restaurant Scraper (Docker) ==="
if ($FastMode) {
    Write-Host "Mode: FAST (HTTP-only, ~20 results/cell)"
} else {
    Write-Host "Mode: BROWSER (depth=$Depth, max coverage)"
}
Write-Host "Docker image: $DockerImage"
Write-Host "Total coordinates: $totalCoords"
Write-Host "Already completed: $completed"
Write-Host "Remaining: $remaining"
Write-Host "Delay between requests: ${Delay}s"
Write-Host "Output: $OutputFile"
Write-Host "============================================="
Write-Host ""

if ($remaining -le 0) {
    Write-Host "All coordinates already scraped! Run dedup_results.py to finalize."
    exit 0
}

# --- Scraping loop ---
$scraped = 0
$errors = 0
$startTime = Get-Date
$tmpFile = [System.IO.Path]::GetTempFileName()

try {
    foreach ($coord in $allCoords) {
        $coord = $coord.Trim()
        if (-not $coord) { continue }

        # Skip already-completed coordinates
        if ($completedSet.Contains($coord)) {
            continue
        }

        $scraped++
        $done = $completed + $scraped

        # Progress display
        $elapsed = ((Get-Date) - $startTime).TotalSeconds
        if ($elapsed -gt 0 -and $scraped -gt 1) {
            $rate = [math]::Round($scraped / $elapsed, 2)
            if ($rate -gt 0) {
                $etaSecs = [int](($totalCoords - $done) / $rate)
                $etaH = [math]::Floor($etaSecs / 3600)
                $etaM = [math]::Floor(($etaSecs % 3600) / 60)
                $etaStr = "${etaH}h${etaM}m"
            } else {
                $etaStr = "calculating..."
            }
        } else {
            $rate = "?"
            $etaStr = "calculating..."
        }

        $pctComplete = [math]::Min(100, [int](($done / $totalCoords) * 100))
        Write-Progress -Activity "Singapore Restaurant Scraper" `
            -Status "[$done/$totalCoords] Scraping $coord ($rate cells/s, ETA: $etaStr, errors: $errors)" `
            -PercentComplete $pctComplete

        # Ensure temp file exists and is empty (Docker bind mount needs an existing file)
        [System.IO.File]::WriteAllText($tmpFile, "", [System.Text.UTF8Encoding]::new($false))

        # Build Docker args
        # --init: proper PID 1 signal forwarding and zombie reaping for Chromium child processes
        # --shm-size: Chromium needs more than Docker's default 64MB /dev/shm
        $dockerArgs = @(
            "run", "--rm",
            "--init",
            "--shm-size=1g",
            "-v", "${QueryFile}:/input.txt",
            "-v", "${tmpFile}:/results.csv",
            $DockerImage,
            "-geo", $coord,
            "-zoom", "18",
            "-lang", "en",
            "-c", "1",
            "-input", "/input.txt",
            "-results", "/results.csv"
        )

        if ($FastMode) {
            $dockerArgs += @("-fast-mode", "-radius", "150", "-exit-on-inactivity", "30s")
        } else {
            $dockerArgs += @("-depth", "$Depth", "-exit-on-inactivity", "3m")
        }

        # Run scraper with retries
        $success = $false
        for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
            & docker @dockerArgs 2>> $ErrorLog
            if ($LASTEXITCODE -eq 0) {
                $success = $true
                break
            } else {
                Add-Content -Path $ErrorLog -Value "`n=== RETRY $attempt/$MaxRetries for $coord ==="
                Start-Sleep -Seconds 2
                [System.IO.File]::WriteAllText($tmpFile, "", [System.Text.UTF8Encoding]::new($false))
            }
        }

        if ($success) {
            # Append results (skip CSV header) to master output
            if ((Test-Path $tmpFile) -and ((Get-Item $tmpFile).Length -gt 0)) {
                $lines = [System.IO.File]::ReadAllLines($tmpFile)
                if ($lines.Count -gt 1) {
                    $dataLines = $lines[1..($lines.Count - 1)]
                    [System.IO.File]::AppendAllLines($OutputFile, $dataLines, [System.Text.UTF8Encoding]::new($false))
                }
            }
        } else {
            $errors++
        }

        # Mark coordinate as completed
        Add-Content -Path $ProgressLog -Value $coord -NoNewline:$false
        $null = $completedSet.Add($coord)

        # Clean temp file for next iteration
        [System.IO.File]::WriteAllText($tmpFile, "", [System.Text.UTF8Encoding]::new($false))

        # Rate limiting delay
        Start-Sleep -Seconds $Delay
    }
} finally {
    # Cleanup temp files
    Write-Progress -Activity "Singapore Restaurant Scraper" -Completed
    if (Test-Path $tmpFile) { Remove-Item $tmpFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path $QueryFile) { Remove-Item $QueryFile -Force -ErrorAction SilentlyContinue }
}

# --- Final report ---
Write-Host ""
Write-Host ""
Write-Host "=== Scraping Complete ==="
$totalRows = ([System.IO.File]::ReadAllLines($OutputFile)).Count - 1
Write-Host "Total rows collected: $totalRows"
Write-Host "Errors encountered: $errors"
Write-Host "Output file: $OutputFile"
Write-Host ""
Write-Host "Next step: python dedup_results.py $OutputFile singapore_restaurants.csv"
