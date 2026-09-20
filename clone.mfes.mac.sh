#!/usr/bin/env bash
set -euo pipefail

# clone.mfes.mac.sh
# Clone all MFE repositories for the macOS development environment.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/mfe-infra"

REPOS=(
    "shell|https://github.com/sivamedia/shell.git"
    "users|https://github.com/sivamedia/users.git"
    "products|https://github.com/sivamedia/products.git"
    "orders|https://github.com/sivamedia/orders.git"
)

log() {
    echo
    echo "============================================================"
    echo "=== $1"
    echo "============================================================"
}

fail() {
    echo
    echo "ERROR: $1" >&2
    exit 1
}

log "Checking prerequisites"

command -v git >/dev/null 2>&1 || fail "Git was not found. Install Git first."

echo "Git: $(git --version)"

log "Creating project directory"

mkdir -p "$PROJECT_ROOT"
echo "Project root: $PROJECT_ROOT"

cd "$PROJECT_ROOT"

log "Cloning MFE repositories"

for repo in "${REPOS[@]}"; do
    IFS='|' read -r name url <<< "$repo"

    target="$PROJECT_ROOT/$name"

    if [[ -d "$target/.git" ]]; then
        echo
        echo "$name already exists. Updating..."

        cd "$target"

        git fetch origin
        git checkout main
        git pull --ff-only origin main

        echo "Updated: $name"

        cd "$PROJECT_ROOT"

    elif [[ -e "$target" ]]; then
        fail "$target exists but is not a Git repository. Rename/remove it and run the script again."

    else
        echo
        echo "Cloning $name..."

        git clone --branch main "$url" "$target"

        echo "Cloned: $name"
    fi
done

log "MFE repositories ready"

printf "%-12s %s\n" "Repository" "Path"
printf "%-12s %s\n" "----------" "----"

for name in shell users products orders; do
    printf "%-12s %s\n" "$name" "$PROJECT_ROOT/$name"
done

echo
echo "Project root:"
echo "  $PROJECT_ROOT"

echo
echo "Next step:"
echo "  cd \"$PROJECT_ROOT\""

echo
echo "MFE repositories:"
echo "  shell"
echo "  users"
echo "  products"
echo "  orders"

echo
echo "Clone/update completed successfully."
