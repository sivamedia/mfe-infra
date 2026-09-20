
# MFE Infrastructure Setup - Linux
# Requires PowerShell 7+, Docker, kubectl, and a running Kubernetes cluster.
# Run from the mfe-infra directory:
#   pwsh ./setup-linux.ps1
#
# The script builds the four MFE images, installs ingress-nginx when needed,
# applies the Kubernetes manifests, waits for readiness, and configures /etc/hosts.

$ErrorActionPreference = "Stop"

$InfraRoot = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $InfraRoot
$K8sRoot = Join-Path $InfraRoot "k8s"

$Apps = @("orders", "products", "shell", "users")

$Images = @(
    @{ Name = "mfe-shell:1.0";    DockerFile = "shell/.dockerFile";    Context = "shell" },
    @{ Name = "mfe-users:1.0";    DockerFile = "users/.dockerFile";    Context = "users" },
    @{ Name = "mfe-products:1.0"; DockerFile = "products/.dockerFile"; Context = "products" },
    @{ Name = "mfe-orders:1.0";   DockerFile = "orders/.dockerFile";   Context = "orders" }
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
            $ready = kubectl get nodes --no-headers 2>$null | Select-String "\sReady\s"
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

function Add-HostsEntries {
    $HostsFile = "/etc/hosts"

    if (-not (Test-Path $HostsFile)) {
        throw "$HostsFile was not found."
    }

    try {
        $content = @(Get-Content $HostsFile -ErrorAction Stop)
    }
    catch {
        throw "Cannot read $HostsFile. Run PowerShell with sudo or use an elevated shell."
    }

    foreach ($HostName in $Hosts) {
        $entry = "127.0.0.1 $HostName"
        $existing = $content | Where-Object {
            $_ -match "^\s*127\.0\.0\.1\s+$([regex]::Escape($HostName))(\s|$)"
        }

        if (-not $existing) {
            & sudo sh -c "printf '%s\n' '$entry' >> /etc/hosts"
            if ($LASTEXITCODE -ne 0) {
                throw "Failed to add $HostName to /etc/hosts."
            }
            $content += $entry
            Write-Host "Added: $entry" -ForegroundColor Green
        }
        else {
            Write-Host "Already present: $entry" -ForegroundColor DarkGray
        }
    }
}

Step "Checking prerequisites"
Require-Command "docker"
Require-Command "kubectl"

Step "Starting Docker"

if ($IsMacOS) {
    throw "This is the Linux setup script. Use setup-macos.ps1 on macOS."
    exit
    $DockerApp = "/Applications/Docker.app"

    if (-not (Test-Path $DockerApp)) {
        throw "Docker Desktop was not found at /Applications/Docker.app."
    }

    $dockerProcess = Get-Process "Docker" -ErrorAction SilentlyContinue

    if (-not $dockerProcess) {
        Write-Host "Starting Docker Desktop..." -ForegroundColor Yellow
        Start-Process "open" -ArgumentList "-a","Docker"
    }

    Wait-Docker
}
if ($IsLinux) {
    docker info *> $null

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Docker Engine is not running. Starting docker.service..." -ForegroundColor Yellow
        & sudo systemctl start docker

        if ($LASTEXITCODE -ne 0) {
            throw "Could not start Docker. Try: sudo systemctl status docker"
        }
    }

    Wait-Docker
}
else {
    throw "This script supports Linux only."
}

Step "Checking Kubernetes"

$context = kubectl config current-context 2>$null

if (-not $context) {
    throw "No kubectl context is configured."
}

Write-Host "Current Kubernetes context: $context" -ForegroundColor Green

$nodes = kubectl get nodes --no-headers 2>$null

if ($LASTEXITCODE -ne 0 -or -not $nodes) {
    Wait-Kubernetes
}
else {
    $ready = kubectl get nodes --no-headers 2>$null | Select-String "\sReady\s"
    if (-not $ready) {
        Wait-Kubernetes
    }
    else {
        Write-Host "Kubernetes is already ready." -ForegroundColor Green
        kubectl get nodes
    }
}

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
    docker build -f $DockerFile -t $Image.Name $BuildContext

    if ($LASTEXITCODE -ne 0) {
        throw "Docker build failed for $($Image.Name)."
    }
}

Step "Creating MFE namespace"
kubectl apply -f (Join-Path $K8sRoot "namespace.yaml")

Step "Checking ingress-nginx"

$IngressClass = kubectl get ingressclass nginx --ignore-not-found 2>$null

if (-not $IngressClass) {
    Write-Host "Installing ingress-nginx..." -ForegroundColor Yellow
    kubectl apply -f $IngressManifest

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install ingress-nginx."
    }
}
else {
    Write-Host "NGINX Ingress controller is already installed." -ForegroundColor Green
}

kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s

if ($LASTEXITCODE -ne 0) {
    throw "ingress-nginx controller did not become ready."
}

Step "Applying MFE deployments"

foreach ($App in $Apps) {
    $file = Join-Path $K8sRoot "$App/deployment.yaml"

    if (-not (Test-Path $file)) {
        throw "Deployment manifest not found: $file"
    }

    kubectl apply -f $file
}

Step "Applying MFE services"

foreach ($App in $Apps) {
    $file = Join-Path $K8sRoot "$App/service.yaml"

    if (-not (Test-Path $file)) {
        throw "Service manifest not found: $file"
    }

    kubectl apply -f $file
}

Step "Applying MFE ingress"

kubectl apply -f (Join-Path $K8sRoot "ingress.yaml")

Step "Waiting for MFE deployments"

foreach ($App in $Apps) {
    kubectl rollout status deployment/$App -n mfe --timeout=120s
}

Step "Configuring /etc/hosts"

Add-HostsEntries

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

http://mfe.local
http://products.mfe.local
http://orders.mfe.local
http://users.mfe.local

Module Federation manifests:

http://products.mfe.local/mf-manifest.json
http://orders.mfe.local/mf-manifest.json
http://users.mfe.local/mf-manifest.json

============================================================
"@
