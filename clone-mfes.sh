#!/usr/bin/env bash
set -euo pipefail

# Clone/update all Micro Frontend repositories into the current mfe-infra folder.
# Run this script from inside the mfe-infra directory.

REPOS=(
  "https://github.com/sivamedia/users.git"
  "https://github.com/sivamedia/products.git"
  "https://github.com/sivamedia/orders.git"
  "https://github.com/sivamedia/shell.git"
)

echo "MFE repository bootstrap"
echo "Working directory: $(pwd)"
echo

for repo in "${REPOS[@]}"; do
  name="$(basename "$repo" .git)"

  if [[ -d "$name/.git" ]]; then
    echo "[$name] already cloned - pulling latest main..."
    git -C "$name" fetch origin
    git -C "$name" checkout main
    git -C "$name" pull --ff-only origin main
  elif [[ -e "$name" ]]; then
    echo "ERROR: '$name' exists but is not a Git repository."
    echo "Remove or rename it, then run the script again."
    exit 1
  else
    echo "[$name] cloning..."
    git clone --branch main "$repo" "$name"
  fi

  echo "[$name] OK"
  echo
done

echo "All MFE repositories are ready:"
for repo in "${REPOS[@]}"; do
  printf '  - %s\n' "$(basename "$repo" .git)"
done
