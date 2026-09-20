# MFE Infrastructure Setup
# Run from Administrator PowerShell:
#   powershell -ExecutionPolicy Bypass -File .\setup.ps1
#
# Expected repo layout:
# mfe-infra\
#   setup.ps1
#   k8s\
#     namespace.yaml
#     ingress.yaml
#     orders\deployment.yaml
#     orders\service.yaml
#     products\deployment.yaml
#     products\service.yaml
#     shell\deployment.yaml
#     shell\service.yaml
#     users\deployment.yaml
#     users\service.yaml

$ErrorActionPreference = "Stop"

$InfraRoot = $PSScriptRoot
$ProjectRoot = Split-Path -Parent $InfraRoot
$K8sRoot = Join-Path $InfraRoot "k8s"

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
        throw "$Command was not found."
    }
}

function Run-Checked($Description, $Command) {
    Write-Host $Description -ForegroundColor Yellow
    & $Command
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed: $Description"
    }
}

# ------------------------------------------------------------
# 1. Prerequisites
# ------------------------------------------------------------

Step "Checking prerequisites"

Require-Command "docker"
Require-Command "kubectl"

# ------------------------------------------------------------
# 2. Start Docker Desktop if necessary
# ------------------------------------------------------------

Write-Host "Checking Docker Desktop..." -ForegroundColor Yellow

$DockerDesktopProcess = Get-Process "Docker Desktop" -ErrorAction SilentlyContinue

if (-not $DockerDesktopProcess) {
    Write-Host "Docker Desktop is not running. Starting it..." -ForegroundColor Yellow

    $DockerDesktopExe = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"

    if (Test-Path $DockerDesktopExe) {
        Start-Process -FilePath $DockerDesktopExe
    }
    else {
        $DockerDesktopExe = Join-Path ${env:ProgramFiles(x86)} "Docker\Docker\Docker Desktop.exe"

        if (Test-Path $DockerDesktopExe) {
            Start-Process -FilePath $DockerDesktopExe
        }
        else {
            throw "Docker Desktop executable was not found."
        }
    }
}

# ------------------------------------------------------------
# 3. Wait for Docker Engine
# ------------------------------------------------------------

$DockerReady = $false

for ($i = 1; $i -le 60; $i++) {
    docker info *> $null

    if ($LASTEXITCODE -eq 0) {
        $DockerReady = $true
        break
    }

    Write-Host "Waiting for Docker Engine... ($i/60)" -ForegroundColor DarkGray
    Start-Sleep -Seconds 2
}

if (-not $DockerReady) {
    throw "Docker Engine did not become ready within 2 minutes."
}

Write-Host "Docker Engine is ready." -ForegroundColor Green

# ------------------------------------------------------------
# 4. Ensure docker-desktop Kubernetes context
# ------------------------------------------------------------

Step "Checking Kubernetes"

$Context = kubectl config current-context 2>$null

if ($Context -ne "docker-desktop") {
    Write-Host "Current context: $Context" -ForegroundColor Yellow
    Write-Host "Switching to docker-desktop..." -ForegroundColor Yellow

    kubectl config use-context docker-desktop

    if ($LASTEXITCODE -ne 0) {
        throw "Kubernetes context 'docker-desktop' is not available."
    }
}

# ------------------------------------------------------------
# 5. Check Kubernetes immediately first
#    Do NOT wait if it is already ready.
# ------------------------------------------------------------

$KubernetesReady = $false

$NodeStatus = kubectl get nodes --no-headers 2>$null

if ($LASTEXITCODE -eq 0 -and $NodeStatus) {
    $ReadyNodes = kubectl get nodes --no-headers 2>$null |
        Select-String "\sReady\s"

    if ($ReadyNodes) {
        $KubernetesReady = $true
        Write-Host "Kubernetes is already ready." -ForegroundColor Green
    }
}

# ------------------------------------------------------------
# 6. Wait only when Kubernetes is actually unavailable
# ------------------------------------------------------------

if (-not $KubernetesReady) {
    Write-Host "Kubernetes is not ready. Waiting for Docker Desktop Kubernetes..." -ForegroundColor Yellow

    for ($i = 1; $i -le 60; $i++) {
        $NodeStatus = kubectl get nodes --no-headers 2>$null

        if ($LASTEXITCODE -eq 0 -and $NodeStatus) {
            $ReadyNodes = kubectl get nodes --no-headers 2>$null |
                Select-String "\sReady\s"

            if ($ReadyNodes) {
                $KubernetesReady = $true
                break
            }
        }

        Write-Host "Waiting for Kubernetes... ($i/60)" -ForegroundColor DarkGray
        Start-Sleep -Seconds 2
    }
}

if (-not $KubernetesReady) {
    throw "Docker Desktop Kubernetes did not become Ready within 2 minutes. Check Docker Desktop > Settings > Kubernetes."
}

kubectl get nodes

# ------------------------------------------------------------
# 7. Build MFE Docker images
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

    docker build -f $DockerFile -t $Image.Name $BuildContext

    if ($LASTEXITCODE -ne 0) {
        throw "Docker build failed for $($Image.Name)."
    }
}

# ------------------------------------------------------------
# 8. Create namespace
# ------------------------------------------------------------

Step "Creating MFE namespace"

kubectl apply -f (Join-Path $K8sRoot "namespace.yaml")

if ($LASTEXITCODE -ne 0) {
    throw "Failed to create/apply the mfe namespace."
}

# ------------------------------------------------------------
# 9. Install ingress-nginx only if missing
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

kubectl rollout status deployment/ingress-nginx-controller `
    -n ingress-nginx `
    --timeout=180s

if ($LASTEXITCODE -ne 0) {
    throw "ingress-nginx controller did not become ready."
}

# ------------------------------------------------------------
# 10. Apply deployments
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
# 11. Apply services
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
# 12. Apply ingress
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
# 13. Wait for application deployments
# ------------------------------------------------------------

Step "Waiting for MFE deployments"

foreach ($App in $Apps) {
    kubectl rollout status deployment/$App -n mfe --timeout=120s

    if ($LASTEXITCODE -ne 0) {
        throw "$App deployment did not become ready."
    }
}

# ------------------------------------------------------------
# 14. Configure Windows hosts
# ------------------------------------------------------------

Step "Configuring Windows hosts file"

$HostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"

try {
    $HostsContent = @(Get-Content $HostsFile -ErrorAction Stop)
}
catch {
    throw "Cannot read $HostsFile. Run this script from Administrator PowerShell."
}

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
# 15. Final status
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
