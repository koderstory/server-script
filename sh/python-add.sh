#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Usage information
to_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
usage() {
  cat <<EOF
Usage: $0 -u USERNAME -v PYTHON_VERSION [-v PYTHON_VERSION ...] [-o] [-h]

Options:
  -u USERNAME         User to install pyenv for (required)
  -v VERSION          Python version to install (can be specified multiple times; at least one required)
  -o                  Overwrite existing pyenv installation if present
  -h                  Show this help message and exit
EOF
  exit 1
}

# Parse CLI options
OVERWRITE=0
declare -a PYTHON_VERSIONS=()
while getopts ":u:v:oh" opt; do
  case "${opt}" in
    u) USERNAME="${OPTARG}" ;;
    v) PYTHON_VERSIONS+=("${OPTARG}") ;;
    o) OVERWRITE=1 ;;
    h) usage ;;
    *) usage ;;
  esac
done

# Validate parameters
if [ -z "${USERNAME:-}" ] || [ "${#PYTHON_VERSIONS[@]}" -eq 0 ]; then
  usage
fi
if ! id "${USERNAME}" &>/dev/null; then
  echo "❌ User '${USERNAME}' does not exist." >&2
  exit 1
fi
USER_HOME="/home/${USERNAME}"
PYENV_ROOT="${USER_HOME}/.pyenv"

# Optionally remove existing pyenv
if [ -d "${PYENV_ROOT}" ]; then
  if [ "${OVERWRITE}" -eq 1 ]; then
    echo "🗑 Removing existing pyenv at ${PYENV_ROOT}..."
    rm -rf "${PYENV_ROOT}"
  else
    echo "⚠️  pyenv already installed for ${USERNAME}; skipping installation."
    SKIP_PYENV=1
  fi
fi

# Install build dependencies (once)
echo "🔧 Installing build dependencies..."
apt-get update
apt-get install -y --no-install-recommends \
  make build-essential libssl-dev zlib1g-dev \
  libbz2-dev libreadline-dev libsqlite3-dev \
  wget curl llvm libncurses-dev xz-utils tk-dev \
  libffi-dev liblzma-dev

# Install pyenv if needed
if [ -z "${SKIP_PYENV:-}" ]; then
  echo "🚀 Installing pyenv into ${PYENV_ROOT}..."
  sudo -u "${USERNAME}" -H env HOME="${USER_HOME}" bash -lc 'curl https://pyenv.run | bash'

  # Configure ~/.bash_profile for pyenv initialization
  echo "⚙️  Configuring ~/.bash_profile for ${USERNAME}..."
  sudo -u "${USERNAME}" -H bash -lc 'cat >> "$HOME/.bash_profile" << "EOF"
export PYENV_ROOT="$HOME/.pyenv"
export PATH="$PYENV_ROOT/bin:$PATH"
if command -v pyenv 1>/dev/null 2>&1; then
  eval "$(pyenv init --path)"
  eval "$(pyenv init -)"
fi
if [ -f ~/.bashrc ]; then
  source ~/.bashrc
fi
# End pyenv configuration
EOF'

  # Ensure login shells source ~/.bash_profile
  echo "🔄 Ensuring ~/.profile sources ~/.bash_profile..."
  sudo -u "${USERNAME}" -H bash -lc 'grep -qxF "if [ -f \"$HOME/.bash_profile\" ]; then source \"$HOME/.bash_profile\"; fi" "$HOME/.profile" || cat >> "$HOME/.profile" << "EOF"
# Source Bash Profile for login shells
if [ -f "$HOME/.bash_profile" ]; then
  source "$HOME/.bash_profile"
fi
EOF'
else
  echo "ℹ️  Skipped pyenv installation."
fi

# Install specified Python versions in one go and set global
if [ -d "${PYENV_ROOT}" ]; then
  echo "🐍 Installing Python version(s): ${PYTHON_VERSIONS[*]}..."
  # Use login shell to ensure pyenv is initialized
  sudo -i -u "${USERNAME}" pyenv install --skip-existing ${PYTHON_VERSIONS[*]}
fi

echo "✅ Done! Installed pyenv and Python version(s) for '${USERNAME}'."
