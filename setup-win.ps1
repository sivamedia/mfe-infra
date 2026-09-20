#requires -Version 5.1

# ============================================================
# MFE Infrastructure Setup - Windows
#
# Run from mfe-infra in Administrator PowerShell:
#   Set-ExecutionPolicy -Scope Process Bypass
#   .\setup-win.ps1
#
# Expected repo layout:
# mfe-infra\
#   setup-win.ps1
#   setup-macos.sh
#   setup-linux.sh
#   k8s\
# ============================================================

$ErrorActionPreference = "Stop"

$InfraRoot   = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $InfraRoot
$K8sRoot     = Join-Path $InfraRoot "k8s"

$Apps = @("orders", "products", "shell", "users")

$Images = @(
    @{ Name = "mfe-shell:1.0";    DockerFile = "shell\.dockerFile";    Context = "shell" },
    @{ Name = "mfe-users:1.0";    DockerFile = "users\.dockerFile";    Context = "users" },
    @{ Name = "mfe-products:1.0"; DockerFile = "products\.dockerFile"; Context = "products" },
    @{ Name = "mfe-orders:1.0";   DockerFile = "orders\.dockerFile";   Context = "orders" }
)

$Hosts = @(
    "mfe.local",
    "products.mfe.local",
    "orders.mfe.local",
    "users.mfe.local"
)

$IngressManifest = "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.13.3/deploy/static/provider/cloud/deploy.yaml"

function Step($Message) {
    Write-Host "`n=== $Message ===" -ForegroundColor Cyan
}

function Require-Command($Command) {
    if (-not (Get-Command $Command -ErrorAction SilentlyContinue)) {
        throw "$Command was not found. Install it first."
    }
}

function Wait-Docker {
    for ($i = 1; $i -le 60; $i++) {
        docker info *> $null

        if ($LASTEXITCODE -eq 0) {
            Write-Host "Docker Engine is ready." -ForegroundColor Green
            return
        }

        Write-Host "Waiting for Docker Engine... ($i/60)" -ForegroundColor DarkGray
        Start-Sleep -Seconds 2
    }

    throw "Docker Engine did not become ready within 2 minutes."
}

function Wait-Kubernetes {
    for ($i = 1; $i -le 60; $i++) {
        $nodes = kubectl get nodes --no-headers 2>$null

        if ($LASTEXITCODE -eq 0 -and $nodes) {
            $ready = kubectl get nodes --no-headers 2>$null |
                Select-String "\sReady\s"

            if ($ready) {
                Write-Host "Kubernetes is ready." -ForegroundColor Green
                kubectl get nodes
                return
            }
        }

        Write-Host "Waiting for Kubernetes... ($i/60)" -ForegroundColor DarkGray
        Start-Sleep -Seconds 2
    }

    throw "Kubernetes did not become Ready within 2 minutes."
}

# ------------------------------------------------------------
# Administrator check
# ------------------------------------------------------------

Step "Checking Administrator privileges"

$CurrentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$Principal = New-Object Security.Principal.WindowsPrincipal($CurrentIdentity)

if (-not $Principal.IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)) {
    throw "Run this script from Administrator PowerShell."
}

# ------------------------------------------------------------
# Prerequisites
# ------------------------------------------------------------

Step "Checking prerequisites"

Require-Command "docker"
Require-Command "kubectl"

# ------------------------------------------------------------
# Start Docker Desktop
# ------------------------------------------------------------

Step "Starting Docker Desktop"

$DockerDesktopExe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"

if (-not (Test-Path $DockerDesktopExe)) {
    $DockerDesktopExe = Join-Path ${env:ProgramFiles(x86)} "Docker\Docker\Docker Desktop.exe"
}

if (-not (Test-Path $DockerDesktopExe)) {
    throw "Docker Desktop executable was not found."
}

$DockerDesktopProcess = Get-Process "Docker Desktop" -ErrorAction SilentlyContinue

if (-not $DockerDesktopProcess) {
    Write-Host "Docker Desktop is not running. Starting it..." -ForegroundColor Yellow
    Start-Process -FilePath $DockerDesktopExe
}

Wait-Docker

# ------------------------------------------------------------
# Kubernetes
# ------------------------------------------------------------

Step "Checking Kubernetes"

$Context = kubectl config current-context 2>$null

if (-not $Context) {
    throw "No kubectl context is configured."
}

Write-Host "Current Kubernetes context: $Context" -ForegroundColor Green

$Nodes = kubectl get nodes --no-headers 2>$null

if ($LASTEXITCODE -eq 0 -and $Nodes) {
    $ReadyNodes = kubectl get nodes --no-headers 2>$null |
        Select-String "\sReady\s"

    if ($ReadyNodes) {
        Write-Host "Kubernetes is already ready." -ForegroundColor Green
        kubectl get nodes
    }
    else {
        Wait-Kubernetes
    }
}
else {
    Wait-Kubernetes
}

# ------------------------------------------------------------
# Build Docker images
# ------------------------------------------------------------

Step "Building MFE Docker images"

foreach ($Image in $Images) {

    $DockerFile = Join-Path $ProjectRoot $Image.DockerFile
    $BuildContext = Join-Path $ProjectRoot $Image.Context

    if (-not (Test-Path $DockerFile)) {
        throw "Dockerfile not found: $DockerFile"
    }

    if (-not (Test-Path $BuildContext)) {
        throw "Build context not found: $BuildContext"
    }

    Write-Host "`nBuilding $($Image.Name)..." -ForegroundColor Yellow

    docker build `
        -f $DockerFile `
        -t $Image.Name `
        $BuildContext

    if ($LASTEXITCODE -ne 0) {
        throw "Docker build failed for $($Image.Name)."
    }
}

# ------------------------------------------------------------
# Namespace
# ------------------------------------------------------------

Step "Creating MFE namespace"

kubectl apply -f (Join-Path $K8sRoot "namespace.yaml")

if ($LASTEXITCODE -ne 0) {
    throw "Failed to apply the mfe namespace."
}

# ------------------------------------------------------------
# ingress-nginx
# ------------------------------------------------------------

Step "Checking ingress-nginx"

$IngressClass = kubectl get ingressclass nginx --ignore-not-found 2>$null

if (-not $IngressClass) {

    Write-Host "NGINX Ingress controller is not installed. Installing..." -ForegroundColor Yellow

    kubectl apply -f $IngressManifest

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install ingress-nginx."
    }
}
else {
    Write-Host "NGINX Ingress controller is already installed." -ForegroundColor Green
}

Write-Host "Waiting for ingress-nginx controller..." -ForegroundColor Yellow

kubectl rollout status `
    deployment/ingress-nginx-controller `
    -n ingress-nginx `
    --timeout=180s

if ($LASTEXITCODE -ne 0) {
    throw "ingress-nginx controller did not become ready."
}

# ------------------------------------------------------------
# Deployments
# ------------------------------------------------------------

Step "Applying MFE deployments"

foreach ($App in $Apps) {

    $Deployment = Join-Path $K8sRoot "$App\deployment.yaml"

    if (-not (Test-Path $Deployment)) {
        throw "Deployment manifest not found: $Deployment"
    }

    kubectl apply -f $Deployment

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to apply $App deployment."
    }
}

# ------------------------------------------------------------
# Services
# ------------------------------------------------------------

Step "Applying MFE services"

foreach ($App in $Apps) {

    $Service = Join-Path $K8sRoot "$App\service.yaml"

    if (-not (Test-Path $Service)) {
        throw "Service manifest not found: $Service"
    }

    kubectl apply -f $Service

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to apply $App service."
    }
}

# ------------------------------------------------------------
# Ingress
# ------------------------------------------------------------

Step "Applying MFE ingress"

$Ingress = Join-Path $K8sRoot "ingress.yaml"

if (-not (Test-Path $Ingress)) {
    throw "Ingress manifest not found: $Ingress"
}

kubectl apply -f $Ingress

if ($LASTEXITCODE -ne 0) {
    throw "Failed to apply MFE ingress."
}

# ------------------------------------------------------------
# Wait for deployments
# ------------------------------------------------------------

Step "Waiting for MFE deployments"

foreach ($App in $Apps) {

    kubectl rollout status `
        "deployment/$App" `
        -n mfe `
        --timeout=120s

    if ($LASTEXITCODE -ne 0) {
        throw "$App deployment did not become ready."
    }
}

# ------------------------------------------------------------
# Windows hosts file
# ------------------------------------------------------------

Step "Configuring Windows hosts file"

$HostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"

if (-not (Test-Path $HostsFile)) {
    throw "Hosts file not found: $HostsFile"
}

$HostsContent = @(Get-Content $HostsFile)

foreach ($HostName in $Hosts) {

    $Entry = "127.0.0.1 $HostName"

    $Existing = $HostsContent | Where-Object {
        $_ -match "^\s*127\.0\.0\.1\s+$([regex]::Escape($HostName))(\s|$)"
    }

    if (-not $Existing) {

        Add-Content -Path $HostsFile -Value $Entry

        $HostsContent += $Entry

        Write-Host "Added: $Entry" -ForegroundColor Green
    }
    else {
        Write-Host "Already present: $Entry" -ForegroundColor DarkGray
    }
}

# ------------------------------------------------------------
# Final status
# ------------------------------------------------------------

Step "MFE setup complete"

Write-Host "`n=== MFE Pods ===" -ForegroundColor Green
kubectl get pods -n mfe

Write-Host "`n=== MFE Services ===" -ForegroundColor Green
kubectl get svc -n mfe

Write-Host "`n=== MFE Ingress ===" -ForegroundColor Green
kubectl get ingress -n mfe

Write-Host "`n=== Ingress Controller ===" -ForegroundColor Green
kubectl get pods -n ingress-nginx

Write-Host @"

============================================================
MFE URLs
============================================================

Shell:
  http://mfe.local

Products:
  http://products.mfe.local

Orders:
  http://orders.mfe.local

Users:
  http://users.mfe.local

Module Federation manifests:
  http://products.mfe.local/mf-manifest.json
  http://orders.mfe.local/mf-manifest.json
  http://users.mfe.local/mf-manifest.json

============================================================
Useful commands
============================================================

kubectl get pods -n mfe
kubectl get svc -n mfe
kubectl get ingress -n mfe
kubectl get pods -n ingress-nginx

============================================================
"@
