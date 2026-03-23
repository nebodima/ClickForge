#!/usr/bin/env bash
# Синхронизация с GitHub: add → commit (если есть изменения) → push
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

MSG="${1:-Update ClickForge}"

git add -A
if git diff --cached --quiet; then
  echo "Нет изменений для коммита."
else
  git commit -m "$MSG"
fi

git push
echo "Готово: origin/$(git branch --show-current)"
