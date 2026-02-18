#!/bin/bash

# Adult Hockey Agent - Deployment Script
# Updates the running agent with latest code from GitHub
# Safe to re-run (idempotent)

set -e  # Exit on error

echo "🚀 Adult Hockey Agent - Deployment"
echo "=================================="
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
    error "Do not run this script as root. Run as the application user."
    exit 1
fi

# Verify we're in the project directory
if [ ! -f "package.json" ]; then
    error "Must run this script from the project root directory"
    exit 1
fi

# Verify PM2 is installed
if ! command -v pm2 &> /dev/null; then
    error "PM2 is not installed. Run scripts/setup-server.sh first."
    exit 1
fi

info "Starting deployment..."
echo ""

# ============================================================================
# 1. Check current git status
# ============================================================================
info "Step 1/6: Checking git status..."

if [ -n "$(git status --porcelain)" ]; then
    warn "Working directory has uncommitted changes:"
    git status --short
    echo ""
    read -p "Continue deployment? (y/N) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        error "Deployment cancelled"
        exit 1
    fi
fi

CURRENT_COMMIT=$(git rev-parse --short HEAD)
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
info "Current: $CURRENT_BRANCH @ $CURRENT_COMMIT"
echo ""

# ============================================================================
# 2. Pull latest code from GitHub
# ============================================================================
info "Step 2/6: Pulling latest code from GitHub..."

git fetch origin
git pull origin "$CURRENT_BRANCH"

NEW_COMMIT=$(git rev-parse --short HEAD)

if [ "$CURRENT_COMMIT" = "$NEW_COMMIT" ]; then
    info "Already up to date (no new commits)"
else
    info "Updated from $CURRENT_COMMIT to $NEW_COMMIT"
    echo ""
    info "Recent commits:"
    git log --oneline --max-count=5
fi
echo ""

# ============================================================================
# 3. Install/update dependencies
# ============================================================================
info "Step 3/6: Installing/updating dependencies..."

if [ -f "package-lock.json" ]; then
    npm ci
else
    npm install
fi
echo ""

# ============================================================================
# 4. Build TypeScript
# ============================================================================
info "Step 4/6: Building TypeScript..."
npm run build

if [ ! -d "dist" ]; then
    error "Build failed - dist/ directory not created"
    exit 1
fi

info "Build successful"
echo ""

# ============================================================================
# 5. Restart PM2 process
# ============================================================================
info "Step 5/6: Restarting PM2 process..."

if pm2 list | grep -q "adult-hockey-agent"; then
    pm2 restart adult-hockey-agent
    info "Agent restarted successfully"
else
    warn "Agent not running in PM2, starting it now..."
    pm2 start ecosystem.config.cjs
    pm2 save
    info "Agent started successfully"
fi

echo ""

# ============================================================================
# 6. Post-deploy health check
# ============================================================================
info "Verifying health..."
sleep 5
if curl -sf http://localhost:3000/health > /dev/null; then
    info "Health check passed ✅"
else
    error "Health check FAILED - check logs with: pm2 logs adult-hockey-agent"
    exit 1
fi

echo ""
echo "============================================"
echo -e "${GREEN}✅ Deployment complete!${NC}"
echo "============================================"
echo ""
echo "Deployed: $CURRENT_BRANCH @ $NEW_COMMIT"
echo ""
echo "Useful commands:"
echo ""
echo "  pm2 status                        # Check process status"
echo "  pm2 logs adult-hockey-agent       # Monitor logs"
echo "  curl http://localhost:3000/health  # Manual health check"
echo ""
