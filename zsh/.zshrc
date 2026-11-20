# Make Homebrew available even before a new machine has a .zprofile.
if ! command -v brew &> /dev/null; then
  for brew_path in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$brew_path" ]]; then
      eval "$("$brew_path" shellenv)"
      break
    fi
  done
  unset brew_path
fi

export MANPAGER="nvim +Man!"
export EDITOR="nvim"

# Load zoxide
if command -v zoxide &> /dev/null; then
  eval "$(zoxide init zsh)"
fi

# Load fzf
if command -v fzf &> /dev/null; then
  source <(fzf --zsh)
fi

# lazygit alias
if command -v lazygit &> /dev/null; then
  alias lg="lazygit"
fi

# Change directory alias
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'

# brew alias
alias bu="brew update && brew upgrade -y && brew cleanup"

# yazi
function y() {
	local tmp cwd; tmp="$(mktemp -t "yazi-cwd.XXXXXX")"
	command yazi "$@" --cwd-file="$tmp"
	IFS= read -r -d '' cwd < "$tmp"
	[ "$cwd" != "$PWD" ] && [ -d "$cwd" ] && builtin cd -- "$cwd" || builtin true
	command rm -f -- "$tmp"
}

# Load antidote plugins
if command -v brew &> /dev/null; then
  antidote_path="$(brew --prefix antidote 2>/dev/null)/share/antidote/antidote.zsh"
  if [[ -r "$antidote_path" ]]; then
    source "$antidote_path"
  fi
  unset antidote_path
fi
if command -v antidote &> /dev/null; then
  antidote load
fi

# Load starship
if command -v starship &> /dev/null; then
  eval "$(starship init zsh)"
fi
