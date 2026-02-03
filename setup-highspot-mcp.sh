#!/bin/bash

# AWS Highspot MCP Setup Script
# This script automates the installation and configuration of AWS Highspot MCP
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/setup-highspot-mcp.sh | bash
#   curl -fsSL ... | bash -s -- --no-mwinit
#   ./setup-highspot-mcp.sh --help

set -e

# Default options
SKIP_MWINIT=false
LOCAL_INSTALL=false
SHOW_HELP=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --help|-h)
            SHOW_HELP=true
            shift
            ;;
        --no-mwinit)
            SKIP_MWINIT=true
            shift
            ;;
        --local)
            LOCAL_INSTALL=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Colors (disabled if not interactive)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

print_status() { echo -e "${GREEN}[✓]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[!]${NC} $1"; }
print_error() { echo -e "${RED}[✗]${NC} $1"; }
print_info() { echo -e "    $1"; }

# Help message
if [[ "$SHOW_HELP" == true ]]; then
    echo "AWS Highspot MCP Setup Script"
    echo ""
    echo "Usage:"
    echo "  ./setup-highspot-mcp.sh [OPTIONS]"
    echo "  curl -fsSL <url> | bash"
    echo "  curl -fsSL <url> | bash -s -- [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  -h, --help      Show this help message"
    echo "  --no-mwinit     Skip Midway authentication (run mwinit manually later)"
    echo "  --local         Install ChromeDriver to ~/.local/bin (no sudo required)"
    echo ""
    echo "What this script does:"
    echo "  1. Checks for Python 3.9+"
    echo "  2. Installs uv package manager"
    echo "  3. Installs ChromeDriver (matching your Chrome version)"
    echo "  4. Configures GitLab SSH access"
    echo "  5. Runs Midway authentication (mwinit)"
    echo "  6. Creates MCP config for Kiro"
    echo ""
    echo "Requirements:"
    echo "  - Python 3.9 or higher"
    echo "  - Google Chrome (for ChromeDriver)"
    echo "  - Amazon corporate network access"
    echo ""
    exit 0
fi

echo ""
echo "========================================"
echo "  AWS Highspot MCP Setup Script"
echo "========================================"
echo ""

# Detect OS
OS="unknown"
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS="mac"
    if [[ $(uname -m) == "arm64" ]]; then
        ARCH="mac-arm64"
    else
        ARCH="mac-x64"
    fi
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    OS="linux"
    ARCH="linux64"
fi

# Step 1: Check Python
echo "Step 1: Checking Python..."
if command -v python3 &> /dev/null; then
    PY_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
    PY_MAJOR=$(echo $PY_VERSION | cut -d. -f1)
    PY_MINOR=$(echo $PY_VERSION | cut -d. -f2)
    if [[ $PY_MAJOR -ge 3 && $PY_MINOR -ge 9 ]]; then
        print_status "Python $PY_VERSION found"
    else
        print_error "Python 3.9+ required, found $PY_VERSION"
        echo ""
        print_info "Please upgrade Python and run this script again."
        if [[ "$OS" == "mac" ]]; then
            print_info "Mac: brew install python@3.12"
            print_info "  or download from https://www.python.org/downloads/"
        else
            print_info "Ubuntu/Debian: sudo apt update && sudo apt install python3.12"
            print_info "Amazon Linux/RHEL: sudo yum install python3.12"
            print_info "  or download from https://www.python.org/downloads/"
        fi
        exit 1
    fi
else
    print_error "Python3 not found."
    echo ""
    print_info "Please install Python 3.9+ and run this script again:"
    if [[ "$OS" == "mac" ]]; then
        print_info "Mac: brew install python@3.12"
        print_info "  or download from https://www.python.org/downloads/"
    else
        print_info "Ubuntu/Debian: sudo apt update && sudo apt install python3.12"
        print_info "Amazon Linux/RHEL: sudo yum install python3.12"
        print_info "  or download from https://www.python.org/downloads/"
    fi
    exit 1
fi

# Step 2: Install uv
echo ""
echo "Step 2: Checking uv package manager..."
if command -v uv &> /dev/null; then
    print_status "uv already installed: $(uv --version)"
else
    print_warning "uv not found, installing..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    print_status "uv installed"
fi

# Step 3: ChromeDriver
echo ""
echo "Step 3: Setting up ChromeDriver..."

get_chrome_version() {
    if [[ "$OS" == "mac" ]]; then
        if [[ -d "/Applications/Google Chrome.app" ]]; then
            CHROME_VER=$("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        fi
    else
        if command -v google-chrome &> /dev/null; then
            CHROME_VER=$(google-chrome --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        elif command -v chromium-browser &> /dev/null; then
            CHROME_VER=$(chromium-browser --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        fi
    fi
    echo "$CHROME_VER"
}

# Function to find matching ChromeDriver version from API
find_chromedriver_version() {
    local chrome_ver="$1"
    local chrome_major=$(echo "$chrome_ver" | cut -d. -f1)

    # Query the known-good-versions API
    local versions_json=$(curl -sL "https://googlechromelabs.github.io/chrome-for-testing/known-good-versions-with-downloads.json")

    if [[ -z "$versions_json" ]]; then
        echo ""
        return
    fi

    # First try exact version match
    local exact_match=$(echo "$versions_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
target = '$chrome_ver'
for v in data['versions']:
    if v['version'] == target and 'chromedriver' in v.get('downloads', {}):
        print(v['version'])
        sys.exit(0)
" 2>/dev/null)

    if [[ -n "$exact_match" ]]; then
        echo "$exact_match"
        return
    fi

    # Find the best matching version (same major, closest minor/patch)
    local best_match=$(echo "$versions_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
target = '$chrome_ver'
target_parts = [int(x) for x in target.split('.')]
target_major = target_parts[0]

candidates = []
for v in data['versions']:
    if 'chromedriver' not in v.get('downloads', {}):
        continue
    parts = [int(x) for x in v['version'].split('.')]
    if parts[0] == target_major:
        candidates.append((v['version'], parts))

if not candidates:
    sys.exit(1)

# Sort by version parts descending, pick the one closest but not exceeding target
candidates.sort(key=lambda x: x[1], reverse=True)

# Find best match: prefer versions <= target, otherwise take closest higher
best = None
for ver, parts in candidates:
    if parts <= target_parts:
        best = ver
        break

if not best and candidates:
    # All available versions are higher, take the lowest one
    best = candidates[-1][0]

if best:
    print(best)
" 2>/dev/null)

    echo "$best_match"
}

# Function to get ChromeDriver download URL
get_chromedriver_url() {
    local version="$1"
    local arch="$2"

    local versions_json=$(curl -sL "https://googlechromelabs.github.io/chrome-for-testing/known-good-versions-with-downloads.json")

    echo "$versions_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
target_ver = '$version'
target_arch = '$arch'

for v in data['versions']:
    if v['version'] == target_ver:
        downloads = v.get('downloads', {}).get('chromedriver', [])
        for d in downloads:
            if d['platform'] == target_arch:
                print(d['url'])
                sys.exit(0)
" 2>/dev/null
}

# Check for chromedriver in PATH or common locations
CHROMEDRIVER_FOUND=false
if command -v chromedriver &> /dev/null; then
    CHROMEDRIVER_FOUND=true
elif [[ -x "$HOME/.local/bin/chromedriver" ]]; then
    CHROMEDRIVER_FOUND=true
fi

if [[ "$CHROMEDRIVER_FOUND" == true ]]; then
    print_status "ChromeDriver already installed"
else
    CHROME_VER=$(get_chrome_version)
    if [[ -z "$CHROME_VER" ]]; then
        print_warning "Could not detect Chrome version"
        print_info "Please install ChromeDriver manually:"
        print_info "1. Check your Chrome version at chrome://version/"
        print_info "2. Download from: https://googlechromelabs.github.io/chrome-for-testing/"
        print_info "3. Move to /usr/local/bin/chromedriver"
    else
        print_info "Detected Chrome version: $CHROME_VER"

        print_info "Finding matching ChromeDriver version..."
        DRIVER_VER=$(find_chromedriver_version "$CHROME_VER")

        if [[ -z "$DRIVER_VER" ]]; then
            print_warning "Could not find matching ChromeDriver version"
            print_info "Please install ChromeDriver manually:"
            print_info "1. Visit: https://googlechromelabs.github.io/chrome-for-testing/"
            print_info "2. Download chromedriver for Chrome $(echo $CHROME_VER | cut -d. -f1).x"
            print_info "3. Move to /usr/local/bin/chromedriver"
        else
            print_info "Found matching ChromeDriver: $DRIVER_VER"

            DOWNLOAD_URL=$(get_chromedriver_url "$DRIVER_VER" "$ARCH")

            if [[ -z "$DOWNLOAD_URL" ]]; then
                print_warning "Could not get download URL"
                print_info "Please install ChromeDriver manually from:"
                print_info "https://googlechromelabs.github.io/chrome-for-testing/"
            else
                print_info "Downloading ChromeDriver..."

                TEMP_DIR=$(mktemp -d)
                cd "$TEMP_DIR"

                if curl -sL "$DOWNLOAD_URL" -o chromedriver.zip 2>/dev/null; then
                    unzip -q chromedriver.zip

                    # Find the chromedriver binary (folder name may vary)
                    DRIVER_BIN=$(find . -name "chromedriver" -type f | head -1)

                    if [[ -n "$DRIVER_BIN" ]]; then
                        if [[ "$OS" == "mac" ]]; then
                            xattr -d com.apple.quarantine "$DRIVER_BIN" 2>/dev/null || true
                        fi
                        chmod +x "$DRIVER_BIN"

                        # Install location based on --local flag
                        if [[ "$LOCAL_INSTALL" == true ]]; then
                            mkdir -p "$HOME/.local/bin"
                            mv "$DRIVER_BIN" "$HOME/.local/bin/"
                            print_status "ChromeDriver $DRIVER_VER installed to ~/.local/bin"

                            # Check if ~/.local/bin is in PATH
                            if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
                                print_warning "Add ~/.local/bin to your PATH:"
                                print_info "echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
                            fi
                        else
                            sudo mv "$DRIVER_BIN" /usr/local/bin/
                            print_status "ChromeDriver $DRIVER_VER installed to /usr/local/bin"
                        fi
                    else
                        print_warning "Could not find chromedriver in downloaded archive"
                    fi
                else
                    print_warning "Download failed. Please install manually."
                    print_info "URL: $DOWNLOAD_URL"
                fi

                cd - > /dev/null
                rm -rf "$TEMP_DIR"
            fi
        fi
    fi
fi

# Step 4: GitLab SSH
echo ""
echo "Step 4: Configuring GitLab SSH access..."

SSH_KEY="$HOME/.ssh/id_ecdsa"
if [[ ! -f "$SSH_KEY" ]]; then
    print_info "Generating SSH key..."
    ssh-keygen -t ecdsa -f "$SSH_KEY" -N "" -q
    print_status "SSH key generated"
else
    print_status "SSH key already exists"
fi

if ! grep -q "ssh.gitlab.aws.dev" ~/.ssh/config 2>/dev/null; then
    print_info "Adding GitLab config to ~/.ssh/config..."
    mkdir -p ~/.ssh
    cat >> ~/.ssh/config << 'EOF'

Host ssh.gitlab.aws.dev
  User git
  IdentityFile ~/.ssh/id_ecdsa
  CertificateFile ~/.ssh/id_ecdsa-cert.pub
  IdentitiesOnly yes
  ProxyCommand none
  ProxyJump none
EOF
    print_status "GitLab SSH config added"
else
    print_status "GitLab SSH config already exists"
fi

# Step 5: Midway auth
echo ""
echo "Step 5: Midway Authentication..."
if [[ "$SKIP_MWINIT" == true ]]; then
    print_warning "Skipping mwinit (--no-mwinit specified)"
    print_info "Run manually: mwinit -f -k ~/.ssh/id_ecdsa.pub"
elif command -v mwinit &> /dev/null; then
    # Check if stdin is a terminal (not piped)
    if [[ -t 0 ]]; then
        print_info "Running mwinit (follow the prompts)..."
        mwinit -f -k ~/.ssh/id_ecdsa.pub || mwinit -k ~/.ssh/id_ecdsa.pub
        print_status "Midway authentication complete"
    else
        print_warning "Skipping mwinit (stdin not interactive)"
        print_info "Run manually: mwinit -f -k ~/.ssh/id_ecdsa.pub"
    fi
else
    print_warning "mwinit not found - please run manually after installing"
fi

# Step 6: Configure MCP client
echo ""
echo "Step 6: Configuring MCP client..."

MCP_CONFIG='{
  "mcpServers": {
    "aws_highspot_mcp": {
      "type": "stdio",
      "command": "uvx",
      "args": [
        "--from",
        "git+ssh://git@ssh.gitlab.aws.dev/yunqic/aws-highspot-mcp.git@main",
        "highspot-mcp"
      ],
      "TIMEOUT": 120000,
      "disabled": false
    }
  }
}'

# Kiro config
KIRO_DIR="$HOME/.kiro/settings"
if [[ -d "$HOME/.kiro" ]] || [[ -d "$(dirname "$KIRO_DIR")" ]]; then
    mkdir -p "$KIRO_DIR"
    echo "$MCP_CONFIG" > "$KIRO_DIR/mcp.json"
    print_status "Kiro MCP config created"
else
    print_info "Kiro not detected, creating config anyway..."
    mkdir -p "$KIRO_DIR"
    echo "$MCP_CONFIG" > "$KIRO_DIR/mcp.json"
    print_status "Kiro MCP config created at $KIRO_DIR/mcp.json"
fi

echo ""
echo "========================================"
echo "  Setup Complete!"
echo "========================================"
echo ""

# Show next steps based on what was skipped
NEXT_STEPS=()

if [[ "$SKIP_MWINIT" == true ]] || [[ ! -t 0 ]]; then
    NEXT_STEPS+=("Run: mwinit -f -k ~/.ssh/id_ecdsa.pub")
fi

if [[ "$LOCAL_INSTALL" == true ]] && [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    NEXT_STEPS+=("Add to PATH: export PATH=\"\$HOME/.local/bin:\$PATH\"")
fi

if [[ ${#NEXT_STEPS[@]} -gt 0 ]]; then
    echo -e "${BLUE}Next steps:${NC}"
    for step in "${NEXT_STEPS[@]}"; do
        print_info "→ $step"
    done
    echo ""
fi

print_info "Daily reminder: Run 'mwinit -f -k ~/.ssh/id_ecdsa.pub'"
print_info "to refresh your Midway authentication token."
echo ""
print_status "You can now use AWS Highspot MCP in Kiro!"
echo ""
