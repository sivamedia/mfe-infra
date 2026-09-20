# clone.mfes.win.ps1
# Clone all MFE repositories for the Windows development environment.

$ErrorActionPreference = "Stop"

$ProjectRoot = Join-Path $PSScriptRoot "mfe-infra"

$Repos = @(
    @{ Name = "shell";    Url = "https://github.com/sivamedia/shell.git" },
    @{ Name = "users";    Url = "https://github.com/sivamedia/users.git" },
    @{ Name = "products"; Url = "https://github.com/sivamedia/products.git" },
    @{ Name = "orders";   Url = "https://github.com/sivamedia/orders.git" }
)

function Write-Section($Message) {
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "=== $Message" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Fail($Message) {
    Write-Host ""
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

Write-Section "Checking prerequisites"

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Fail "Git was not found. Install Git for Windows first."
}

Write-Host "Git: $(git --version)"

Write-Section "Creating project directory"

New-Item -ItemType Directory -Force -Path $ProjectRoot | Out-Null
Write-Host "Project root: $ProjectRoot"

Set-Location $ProjectRoot

Write-Section "Cloning MFE repositories"

foreach ($Repo in $Repos) {
    $Target = Join-Path $ProjectRoot $Repo.Name

    if (Test-Path (Join-Path $Target ".git")) {
        Write-Host ""
        Write-Host "$($Repo.Name) already exists. Updating..." -ForegroundColor Yellow

        Push-Location $Target
        try {
            git fetch origin
            git checkout main
            git pull --ff-only origin main
        }
        finally {
            Pop-Location
        }

        Write-Host "Updated: $($Repo.Name)" -ForegroundColor Green
    }
    elseif (Test-Path $Target) {
        Fail "$Target exists but is not a Git repository. Rename/remove it and run the script again."
    }
    else {
        Write-Host ""
        Write-Host "Cloning $($Repo.Name)..." -ForegroundColor Yellow
        git clone --branch main $Repo.Url $Target
        Write-Host "Cloned: $($Repo.Name)" -ForegroundColor Green
    }
}

Write-Section "MFE repositories ready"

Get-ChildItem -Directory $ProjectRoot |
    Where-Object { $_.Name -in @("shell", "users", "products", "orders") } |
    Select-Object Name, FullName |
    Format-Table -AutoSize

Write-Host ""
Write-Host "Project root:" -ForegroundColor Green
Write-Host "  $ProjectRoot"
Write-Host ""
Write-Host "Next step:" -ForegroundColor Green
Write-Host "  cd `"$ProjectRoot`""
Write-Host ""
Write-Host "MFE repositories:"
Write-Host "  shell"
Write-Host "  users"
Write-Host "  products"
Write-Host "  orders"
Write-Host ""
Write-Host "Clone/update completed successfully." -ForegroundColor Green
