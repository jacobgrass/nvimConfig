sudo apt-get update
sudo apt-get install -y cargo npm python3 python3-venv unzip ninja-build gettext cmake curl build-essential git
git clone https://github.com/neovim/neovim.git
cd neovim
sudo make CMAKE_BUILD_TYPE=Release
sudo make CMAKE_EXTRA_FLAGS="-DCMAKE_INSTALL_PREFIX=$HOME/neovim"
sudo make install
sudo export PATH="$HOME/neovim/bin:$PATH"
