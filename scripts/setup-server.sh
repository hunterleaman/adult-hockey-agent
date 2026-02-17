#!/bin/bash

# Adult Hockey Agent - Server Setup Script
# This script sets up a fresh DigitalOcean droplet for running the agent
# Safe to re-run (idempotent)

set -e  # Exit on error

echo "🏒 Adult Hockey Agent - Server Setup"
echo "===================================="
echo ""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    error "Do not run this script as root. Run as the application user with sudo access."
    exit 1
fi

# Verify we're in the project directory
if [ ! -f "package.json" ]; then
    error "Must run this script from the project root directory"
    exit 1
fi

info "Starting server setup..."
echo ""

# ============================================================================
# 1. Update system packages
# ============================================================================
info "Step 1/10: Updating system packages..."
sudo apt update
sudo apt upgrade -y
echo ""

# ============================================================================
# 2. Install Node.js 20 LTS
# ============================================================================
info "Step 2/10: Installing Node.js 20 LTS..."

if command -v node &> /dev/null; then
    NODE_VERSION=$(node --version)
    info "Node.js already installed: $NODE_VERSION"

    # Check if it's version 20
    if [[ $NODE_VERSION == v20.* ]]; then
        info "Node.js 20 LTS already installed, skipping installation"
    else
        warn "Node.js version is not 20 LTS. Installing Node.js 20..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
        sudo apt install -y nodejs
    fi
else
    info "Installing Node.js 20 LTS via NodeSource..."
    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
    sudo apt install -y nodejs
fi

# Verify installation
NODE_VERSION=$(node --version)
NPM_VERSION=$(npm --version)
info "Installed: Node.js $NODE_VERSION, npm $NPM_VERSION"
echo ""

# ============================================================================
# 3. Install git (if not already installed)
# ============================================================================
info "Step 3/10: Checking git installation..."

if command -v git &> /dev/null; then
    GIT_VERSION=$(git --version)
    info "Git already installed: $GIT_VERSION"
else
    info "Installing git..."
    sudo apt install -y git
    GIT_VERSION=$(git --version)
    info "Installed: $GIT_VERSION"
fi
echo ""

# ============================================================================
# 4. Install PM2 globally
# ============================================================================
info "Step 4/10: Installing PM2..."

if command -v pm2 &> /dev/null; then
    PM2_VERSION=$(pm2 --version)
    info "PM2 already installed: v$PM2_VERSION"
else
    info "Installing PM2 globally..."
    sudo npm install -g pm2
    PM2_VERSION=$(pm2 --version)
    info "Installed: PM2 v$PM2_VERSION"
fi
echo ""

# ============================================================================
# 5. Install Playwright dependencies
# ============================================================================
info "Step 5/10: Installing Playwright system dependencies..."
sudo npx playwright install-deps chromium
echo ""

# ============================================================================
# 6. Install project dependencies
# ============================================================================
info "Step 6/10: Installing project dependencies..."

if [ -f "package-lock.json" ]; then
    info "Using npm ci (lockfile exists)..."
    npm ci
else
    warn "No package-lock.json found, using npm install..."
    npm install
fi
echo ""

# ============================================================================
# 7. Build TypeScript
# ============================================================================
info "Step 7/10: Building TypeScript..."
npm run build

if [ ! -d "dist" ]; then
    error "Build failed - dist/ directory not created"
    exit 1
fi

info "Build successful"
echo ""

# ============================================================================
# 8. Create .env file from template
# ============================================================================
info "Step 8/10: Setting up .env file..."

if [ -f ".env" ]; then
    warn ".env file already exists, skipping creation"
    warn "To reconfigure, delete .env and re-run this script"
else
    if [ -f ".env.example" ]; then
        cp .env.example .env
        info "Created .env from .env.example"
        warn "IMPORTANT: Edit .env and add your SLACK_WEBHOOK_URL before starting the agent"
        warn "Run: nano .env"
    else
        error ".env.example not found"
        exit 1
    fi
fi
echo ""

# ============================================================================
# 9. Create required directories
# ============================================================================
info "Step 9/10: Creating required directories..."

# Create data directory for state persistence
if [ ! -d "data" ]; then
    mkdir -p data
    info "Created data/ directory"
else
    info "data/ directory already exists"
fi

# Create logs directory for PM2 logs
if [ ! -d "logs" ]; then
    mkdir -p logs
    info "Created logs/ directory"
else
    info "logs/ directory already exists"
fi
echo ""

# ============================================================================
# 10. Start with PM2 and configure auto-start
# ============================================================================
info "Step 10/10: Starting agent with PM2..."

# Check if already running in PM2
if pm2 list | grep -q "adult-hockey-agent"; then
    warn "Agent already running in PM2"
    info "Restarting agent..."
    pm2 restart adult-hockey-agent
else
    info "Starting agent for the first time..."
    pm2 start ecosystem.config.cjs
fi

# Save PM2 process list
info "Saving PM2 process list..."
pm2 save

# Setup PM2 startup (survives reboot)
info "Configuring PM2 to start on system boot..."
STARTUP_CMD=$(pm2 startup | grep "sudo" | tail -n 1)

if [ -n "$STARTUP_CMD" ]; then
    info "Running PM2 startup command..."
    eval $STARTUP_CMD
else
    info "PM2 startup already configured"
fi

echo ""
echo "============================================"
echo -e "${GREEN}✅ Server setup complete!${NC}"
echo "============================================"
echo ""
echo "Next steps:"
echo ""
echo "1. Configure environment variables:"
echo "   nano .env"
echo "   # Add your SLACK_WEBHOOK_URL"
echo ""
echo "2. Restart the agent:"
echo "   pm2 restart adult-hockey-agent"
echo ""
echo "3. Monitor logs:"
echo "   pm2 logs adult-hockey-agent"
echo ""
echo "4. Check status:"
echo "   pm2 status"
echo ""
echo "5. Test health endpoint:"
echo "   curl http://localhost:3000/health"
echo ""
echo "For full documentation, see docs/DEPLOY.md"
echo ""
