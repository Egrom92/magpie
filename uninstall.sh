#!/bin/bash
# Удаляет Magpie и всю сохранённую историю буфера обмена.
set -euo pipefail
for app in "/Applications/Magpie.app" "$HOME/Applications/Magpie.app"; do
  if [ -d "$app" ]; then
    pkill -x Magpie 2>/dev/null || true
    open -n -W "$app" --args --unregister-login >/dev/null 2>&1 || true
    rm -rf "$app"
  fi
done
rm -rf "$HOME/Library/Application Support/Magpie"
defaults delete local.magpie >/dev/null 2>&1 || true
echo "✓ Magpie удалён вместе с историей."
