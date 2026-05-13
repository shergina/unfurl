#!/bin/sh
#
# Point this clone's git hooks at the versioned scripts/hooks directory.
# Run once per clone.

set -e

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

chmod +x scripts/hooks/* 2>/dev/null || true
git config core.hooksPath scripts/hooks

echo "Installed: core.hooksPath -> scripts/hooks"
echo "The spec reminder now runs on commit. Silence one commit with SPEC_SKIP=1."
