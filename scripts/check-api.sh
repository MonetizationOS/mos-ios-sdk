#!/bin/sh
# Fails a pull request whose public API breaks against the latest v* release tag, unless it adds a changeset with a
# minor or major bump (before 1.0 a break is minor). Skipped until the first tag. Pass the base branch (default main).
set -e
cd "$(dirname "$0")/.."
tag=$(git tag --list 'v*' --sort=-v:refname | head -n 1)
if [ -z "$tag" ]; then
  echo "::notice::check-api skipped: no v* release tag yet"
  exit 0
fi
if swift package diagnose-api-breaking-changes "$tag" --products MonetizationOS MonetizationOSUI; then
  echo "check-api: no breaking change since $tag"
  exit 0
fi
for file in $(git diff --name-only --diff-filter=A "origin/${1:-main}...HEAD" -- '.changeset/*.md'); do
  if grep -Eq "^[\"']?mos-ios-sdk[\"']?: *(minor|major) *$" "$file"; then
    echo "check-api: breaking change since $tag, with a minor or major changeset ($file)"
    exit 0
  fi
done
echo "::error::The public API breaks against $tag (above). Add a minor changeset (see .changeset/README.md), or undo the break."
exit 1
