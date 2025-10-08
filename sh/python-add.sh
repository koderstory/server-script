#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ANSI colors
GREEN="\033[0;32m"
NC="\033[0m"  # No Color

# Usage information
to_lower() { echo -e "${GREEN}$1${NC}" | tr '[:upper:]' '[:lower:]'; }
usage() {
  echo -e "${GREEN}Usage: $0 -u USERNAME -v PYTHON_VERSION [-v PYTHON_VERSION ...] [-G] [-h]${NC}"
  echo -e "${GREEN}Options:${NC}"
  echo -e "${GREEN}  -u USERNAME         User to install pyenv for (required)${NC}"
  echo -e "${GREEN}  -v VERSION          Python version to install (can be specified multiple times; at least one required)${NC}"
  echo -e "${GREEN}  -G                  Make the python version(s) globally available in the user scope${NC}"
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
  echo -e "${GREEN}❌ User '${USERNAME}' does not exist.${NC}" >&2
  exit 1
fi
USER_HOME="/home/${USERNAME}"
PYENV_ROOT="${USER_HOME}/.pyenv"

# Install build dependencies (once)
echo -e "${GREEN}🔧 Installing build dependencies...${NC}"
apt-get update
apt-get install -y --no-install-recommends \
  make build-essential libssl-dev zlib1g-dev \
  libbz2-dev libreadline-dev libsqlite3-dev \
  wget curl llvm libncurses-dev xz-utils tk-dev \
  libffi-dev liblzma-dev

# Install pyenv if needed
if [ ! -d "${PYENV_ROOT}" ]; then
  echo -e "${GREEN}🚀 Installing pyenv into ${PYENV_ROOT}...${NC}"
  sudo -i -u "$USERNAME" bash -lc "curl https://pyenv.run | bash"
else
  echo -e "${GREEN}⏭ ${PYENV_ROOT} already exists; skipping pyenv install.${NC}"
fi

# Configure ~/.bash_profile for pyenv initialization
echo -e "${GREEN}⚙️  Configuring ~/.bash_profile for ${USERNAME}...${NC}"
PROFILE="${USER_HOME}/.bash_profile"
PATTERN='export PYENV_ROOT="'"${USER_HOME}"'/.pyenv"'

if [ -f "$PROFILE" ] && grep -Fq "$PATTERN" "$PROFILE"; then
  echo -e "${GREEN}⏭️  pyenv already configured in $PROFILE, skipping.${NC}"
else
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
  echo -e "${GREEN}✅ Appended pyenv initialization to $PROFILE${NC}"
fi

# Install specified Python versions in one go and set global
if [ -d "${PYENV_ROOT}" ]; then
  echo -e "${GREEN}🐍 Installing Python version(s): ${PYTHON_VERSIONS[*]}...${NC}"
  sudo -i -u "$USERNAME" bash -lc "pyenv install --skip-existing ${PYTHON_VERSIONS[*]}"
  if [ "${SET_GLOBAL}" -eq 1 ]; then
    echo -e "${GREEN}🌐 Setting global Python version(s): ${PYTHON_VERSIONS[*]}...${NC}"
    sudo -i -u "$USERNAME" bash -lc "pyenv global ${PYTHON_VERSIONS[*]}"
  fi

  CURRENT_GLOBAL=$(sudo -i -u "${USERNAME}" bash -lc 'pyenv global')

  if [[ "${CURRENT_GLOBAL}" =~ (^| )system($| ) ]]; then
    echo -e "${GREEN}🌐 Global was 'system'—switching to: ${PYTHON_VERSIONS[*]}...${NC}"
    sudo -i -u "${USERNAME}" bash -lc "pyenv global ${PYTHON_VERSIONS[*]}"
  elif [ "${SET_GLOBAL}" -eq 1 ]; then
    echo -e "${GREEN}🌐 -G passed—setting global to: ${PYTHON_VERSIONS[*]}...${NC}"
    sudo -i -u "$USERNAME" bash -lc "pyenv global ${PYTHON_VERSIONS[*]}"
  else
    echo -e "${GREEN}ℹ️  Leaving global version(s) as: ${CURRENT_GLOBAL}${NC}"
  fi
fi

echo -e "${GREEN}✅ Done! Installed pyenv and Python version(s) for '${USERNAME}'.${NC}"
