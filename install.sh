#!/usr/bin/env bash
# Installs SimpoConverter for the current user on Linux or macOS.
# Requires Python 3 with the venv module. Root access is not required.
#
# Install or reinstall:
#   curl -fsSL https://raw.githubusercontent.com/nambobi/SimpoConverter/main/install.sh | bash
# Uninstall:
#   simpoconv uninstall   (or: bash install.sh --uninstall)
set -e

REPO_RAW="https://raw.githubusercontent.com/nambobi/SimpoConverter/main"
DIR="$HOME/.local/share/simpoconverter"
BIN="$HOME/.local/bin"

if [ "$1" = "--uninstall" ]; then
  rm -rf "$DIR" "$BIN/simpoconv"
  echo "SimpoConverter has been uninstalled."
  exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: Python 3 is required. On Ubuntu/Debian: sudo apt install python3 python3-venv"
  exit 1
fi

echo "Installing SimpoConverter..."
mkdir -p "$DIR" "$BIN"

# 1. Copy the script from this folder if present, otherwise download it.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "$HERE" ] && [ -f "$HERE/simpoconv.py" ] && [ -f "$HERE/requirements.txt" ]; then
  cp "$HERE/simpoconv.py" "$HERE/requirements.txt" "$DIR/"
else
  curl -fsSL "$REPO_RAW/simpoconv.py" -o "$DIR/simpoconv.py"
  curl -fsSL "$REPO_RAW/requirements.txt" -o "$DIR/requirements.txt"
fi

# 2. Create a virtual environment and install pypdfium2 and Pillow in it.
if [ ! -x "$DIR/venv/bin/python" ]; then
  if ! python3 -m venv "$DIR/venv" >/dev/null 2>&1; then
    rm -rf "$DIR/venv"
    echo "Error: cannot create a Python virtual environment."
    echo "On Ubuntu/Debian run: sudo apt install python3-venv, then run this installer again."
    exit 1
  fi
fi
echo "Installing pypdfium2 and Pillow..."
"$DIR/venv/bin/python" -m pip install -q --disable-pip-version-check -r "$DIR/requirements.txt"

# 3. Create the simpoconv command.
cat > "$BIN/simpoconv" <<EOF
#!/bin/sh
exec "$DIR/venv/bin/python" "$DIR/simpoconv.py" "\$@"
EOF
chmod +x "$BIN/simpoconv"

case ":$PATH:" in
  *":$BIN:"*) ;;
  *)
    RC="$HOME/.bashrc"
    [ "$(basename "${SHELL:-bash}")" = "zsh" ] && RC="$HOME/.zshrc"
    # The line is written literally so that $HOME and $PATH expand when the shell starts.
    # shellcheck disable=SC2016
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$RC"
    echo "Added ~/.local/bin to PATH in $RC. Open a new terminal to use simpoconv."
    ;;
esac

VERSION="$("$DIR/venv/bin/python" "$DIR/simpoconv.py" version 2>/dev/null || true)"
echo "${VERSION:-SimpoConverter} installed in $DIR"
echo "Run: simpoconv help"
