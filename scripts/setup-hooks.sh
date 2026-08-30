#!/bin/sh
# Installs the repo's git hooks into .git/hooks (git does not track hooks itself).
# Run once after cloning: ./scripts/setup-hooks.sh

set -e

REPO_ROOT=$(git rev-parse --show-toplevel)
HOOKS_SOURCE="$REPO_ROOT/scripts/git-hooks"
HOOKS_TARGET="$REPO_ROOT/.git/hooks"

for hook in "$HOOKS_SOURCE"/*; do
    name=$(basename "$hook")
    install -m 755 "$hook" "$HOOKS_TARGET/$name"
    echo "Installed $name hook"
done
