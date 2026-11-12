#!/bin/bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
brew bundle install --no-upgrade --file=Brewfile
mkdir -p "$HOME/Library/Rime"
stow --restow --target="$HOME" ghostty hammerspoon linearmouse nvim rime starship zsh
bash scripts/update-rime.sh
