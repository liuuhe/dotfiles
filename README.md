```sh
xcode-select --install
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)"
git clone https://github.com/liuuhe/dotfiles.git ~/dotfiles
bash ~/dotfiles/restore.sh
exec zsh -l
```
