#!/bin/sh
# Fails unless a pull request that changes Sources/ adds a changeset. Pass the base branch (default main).
set -e
cd "$(dirname "$0")/.."
range="origin/${1:-main}...HEAD"
if ! git diff --name-only "$range" -- Sources | grep -q .; then
    echo "check-changeset: no change under Sources/"
    exit 0
fi
if git diff --name-only --diff-filter=A "$range" -- .changeset | grep -v '^.changeset/README.md$' | grep -q '\.md$'; then
    echo "check-changeset: changeset found"
    exit 0
fi
echo "::error::Sources/ changed without a changeset. Run 'pnpm changeset' (see .changeset/README.md), or label the PR no-changelog."
exit 1
