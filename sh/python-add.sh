#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Usage information
to_lower() { echo "$1" | tr '[:upper:]' '[:lower:]'; }
usage() {
  cat <<EOF
Usage: $0 -u USERNAME -v PYTHON_VERSION [-v PYTHON_VERSION ...] [-G] [-h]

Options:
  -u USERNAME         User to install pyenv for (required)
  -v VERSION          Python version to install (can be specified multiple times; at least one required)
  -G                  Make the python version(s) globally available in the user scope
EOF
  exit 1
}

# Parse CLI options
SET_GLOBAL=0
declare -a PYTHON_VERSIONS=()
while getopts ":u:v:G" opt; do
  case "${opt}" in
    u) USERNAME="${OPTARG}" ;;
    v) PYTHON_VERSIONS+=("${OPTARG}") ;;
    G) SET_GLOBAL=1 ;;
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

# Install build dependencies (once)
echo "🔧 Installing build dependencies..."
apt-get update
apt-get install -y --no-install-recommends \
  make build-essential libssl-dev zlib1g-dev \
  libbz2-dev libreadline-dev libsqlite3-dev \
  wget curl llvm libncurses-dev xz-utils tk-dev \
  libffi-dev liblzma-dev

# Install pyenv if needed
if [ ! -d "${PYENV_ROOT}" ]; then
  echo "🚀 Installing pyenv into ${PYENV_ROOT}..."
  sudo -i -u "$USERNAME" bash -lc "curl https://pyenv.run | bash"
else
  echo "⏭ ${PYENV_ROOT} already exists; skipping pyenv install."
fi

# Configure ~/.bash_profile for pyenv initialization
echo "⚙️  Configuring ~/.bash_profile for ${USERNAME}..."
echo "[DEBUG] Testing: -d ${USER_HOME}"
PROFILE="${USER_HOME}/.bash_profile"
PATTERN='export PYENV_ROOT="'"${USER_HOME}"'/.pyenv"'

if [ -f "$PROFILE" ] && grep -Fq "$PATTERN" "$PROFILE"; then
  echo "⏭️  pyenv already configured in $PROFILE, skipping."
else
  # append the whole block
  cat <<EOF | sudo -u "${USERNAME}" tee -a "$PROFILE" >/dev/null
export PYENV_ROOT="${USER_HOME}/.pyenv"
export PATH="\$PYENV_ROOT/bin:\$PATH"
if command -v pyenv >/dev/null 2>&1; then
  eval "\$(pyenv init --path)"
  eval "\$(pyenv init -)"
fi
if [ -f ~/.bashrc ]; then
  source ~/.bashrc
fi
# End pyenv configuration
EOF
  echo "✅ Appended pyenv initialization to $PROFILE"
fi
echo "[DEBUG] Testing: -d ${USER_HOME}"


# Install specified Python versions in one go and set global
if [ -d "${PYENV_ROOT}" ]; then
  echo "🐍 Installing Python version(s): ${PYTHON_VERSIONS[*]}..."
  # Use login shell to ensure pyenv is initialized
  sudo -i -u "$USERNAME" bash -lc "pyenv install --skip-existing ${PYTHON_VERSIONS[*]}"
  if [ "${SET_GLOBAL}" -eq 1 ]; then
    echo "🌐 Setting global Python version(s): ${PYTHON_VERSIONS[*]}..."
    sudo -i -u "$USERNAME" bash -lc "pyenv global ${PYTHON_VERSIONS[*]}"
  fi

  # Figure out what pyenv currently has as the global version
  CURRENT_GLOBAL=$(sudo -i -u "${USERNAME}" bash -lc 'pyenv global')

  # If it's just "system", or if -G was passed, set to our new versions
  if [[ "${CURRENT_GLOBAL}" =~ (^| )system($| ) ]]; then
    echo "🌐 Global was 'system'—switching to: ${PYTHON_VERSIONS[*]}..."
    sudo -i -u "${USERNAME}" bash -lc "pyenv global ${PYTHON_VERSIONS[*]}"
  elif [ "${SET_GLOBAL}" -eq 1 ]; then
    echo "🌐 -G passed—setting global to: ${PYTHON_VERSIONS[*]}..."
    sudo -i -u "${USERNAME}" bash -lc "pyenv global ${PYTHON_VERSIONS[*]}"
  else
    echo "ℹ️  Leaving global version(s) as: ${CURRENT_GLOBAL}"
  fi
fi

echo "✅ Done! Installed pyenv and Python version(s) for '${USERNAME}'."
