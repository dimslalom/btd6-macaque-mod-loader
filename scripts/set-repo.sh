#!/bin/bash
# Points every GitHub URL in the repo (README, Homebrew formula template) at another repository.
# Usage: scripts/set-repo.sh <owner>/<repo>        e.g. scripts/set-repo.sh yourname/macaqueloader
# The Homebrew tap is assumed to be <owner>/homebrew-tap (installed as `brew install <owner>/tap/macaqueloader`).
set -euo pipefail
NEW="${1:?usage: scripts/set-repo.sh <owner>/<repo>}"
case "$NEW" in */*) ;; *) echo "expected <owner>/<repo>" >&2; exit 2;; esac
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CUR="$(sed -n 's#^repo=##p' "$ROOT/packaging/repo.conf")"
new_owner="${NEW%%/*}"; cur_owner="${CUR%%/*}"
cd "$ROOT"
grep -rlF --exclude-dir=.git --exclude-dir=dist --exclude-dir=.cache --exclude=set-repo.sh \
  -e "$CUR" -e "$cur_owner/tap/" -e "$cur_owner/homebrew-tap" . | while IFS= read -r f; do
  sed -i '' -e "s#$CUR#$NEW#g" -e "s#$cur_owner/tap/#$new_owner/tap/#g" \
    -e "s#$cur_owner/homebrew-tap#$new_owner/homebrew-tap#g" "$f"
  echo "updated $f"
done
printf 'repo=%s\n' "$NEW" > packaging/repo.conf
echo "repo is now $NEW"
