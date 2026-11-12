#!/bin/bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
brew bundle install --no-upgrade --file=Brewfile
stow --restow --target="$HOME" ghostty hammerspoon nvim rime starship zsh
