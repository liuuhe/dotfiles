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

# eza alias
if command -v eza &> /dev/null; then
  alias ls='eza -lh --group-directories-first --icons=auto'
  alias la='ls -a'
  alias lt='eza --tree --level=3 --long --icons --git'
  alias lta='lt -a'
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
source $(brew --prefix antidote)/share/antidote/antidote.zsh
antidote load

# Load starship
if command -v starship &> /dev/null; then
  eval "$(starship init zsh)"
fi
