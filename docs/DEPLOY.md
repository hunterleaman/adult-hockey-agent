# Production Deployment Guide

This guide covers deploying the Adult Hockey Agent to a DigitalOcean VPS. The agent runs 24/7 with PM2 process management and survives server reboots.

## Infrastructure Requirements

- **Droplet**: Basic $6/month (1 vCPU, 1GB RAM, 25GB SSD)
- **OS**: Ubuntu 24.04 LTS
- **Region**: NYC1 (or nearest to Charlotte, NC)
- **Node.js**: 20 LTS
- **Process Manager**: PM2
- **Runtime User**: Non-root user with sudo access

## Part 1: Droplet Creation (Manual)

### 1.1 Create Droplet in DigitalOcean

1. Log in to [DigitalOcean](https://cloud.digitalocean.com)
2. Click **Create** → **Droplets**
3. **Choose Region**: NYC1 (or nearest)
4. **Choose Image**: Ubuntu 24.04 LTS
5. **Choose Size**: Basic → $6/month (1GB RAM, 1 vCPU, 25GB SSD)
6. **Choose Authentication**:
   - Select **SSH Key**
   - If you don't have an SSH key, create one locally:
     ```bash
     ssh-keygen -t ed25519 -C "your_email@example.com"
     cat ~/.ssh/id_ed25519.pub  # Copy this
     ```
   - Click **New SSH Key** and paste your public key
7. **Finalize Details**:
   - Hostname: `adult-hockey-agent` (or your preference)
   - Enable **Monitoring** (free)
   - Tags: `production`, `adult-hockey-agent` (optional)
8. Click **Create Droplet**

Wait 60 seconds for the droplet to boot. Note the **IP address** displayed.

### 1.2 Configure Firewall

1. In DigitalOcean dashboard, go to **Networking** → **Firewalls**
2. Click **Create Firewall**
3. **Name**: `adult-hockey-agent-firewall`
4. **Inbound Rules**:
   - SSH: TCP 22 from All IPv4, All IPv6
   - HTTP: TCP 80 from All IPv4, All IPv6 (for future nginx/SSL)
   - HTTPS: TCP 443 from All IPv4, All IPv6 (for future nginx/SSL)
   - Custom: TCP 3000 from All IPv4, All IPv6 (health endpoint - lock down later)
5. **Outbound Rules**:
   - All TCP, All UDP, ICMP to All IPv4, All IPv6
6. **Apply to Droplets**: Select `adult-hockey-agent`
7. Click **Create Firewall**

**Note**: For production, restrict port 3000 to Slack IP ranges only. See [Slack IP Ranges](https://api.slack.com/changelog/2018-08-14-slack-api-to-begin-publishing-ip-address-ranges) for the list.

### 1.3 Initial SSH Connection

```bash
# Test SSH connection
ssh root@YOUR_DROPLET_IP

# You should see Ubuntu welcome message
```

If connection fails, verify:
- Firewall allows SSH (port 22)
- SSH key is loaded in your agent: `ssh-add -l`
- SSH key matches the one added to DigitalOcean

## Part 2: Server Setup (Automated)

### 2.1 Create Non-Root User

```bash
# Still SSH'd as root
adduser adulthockey
# Set a strong password when prompted
# Accept defaults for other prompts (just press Enter)

# Add to sudo group
usermod -aG sudo adulthockey

# Copy SSH keys to new user
rsync --archive --chown=adulthockey:adulthockey ~/.ssh /home/adulthockey

# Switch to new user
su - adulthockey

# Test sudo access
sudo apt update  # Should work without asking for password
```

### 2.2 Run Automated Setup Script

```bash
# Clone the repository
cd ~
git clone https://github.com/hunterleaman/adult-hockey-agent.git
cd adult-hockey-agent

# Make setup script executable
chmod +x scripts/setup-server.sh

# Run setup (this will take 5-10 minutes)
./scripts/setup-server.sh
```

The setup script will:
- Install Node.js 20 LTS
- Install PM2 globally
- Install git (if not already installed)
- Install project dependencies (production only)
- Build TypeScript
- Create `.env` file from template
- Create `data/` directory for state persistence
- Create `logs/` directory for PM2 logs
- Start the agent with PM2
- Configure PM2 to restart on server reboot
- Save PM2 process list

### 2.3 Configure Environment Variables

The setup script creates a `.env` file from `.env.example`. You must edit it to add your Slack webhook:

```bash
# Edit .env file
nano .env
```

**Required**:
```bash
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/YOUR/WEBHOOK/URL
```

**Optional** (defaults shown):
```bash
PORT=3000
POLL_INTERVAL_MINUTES=60
POLL_INTERVAL_ACCELERATED_MINUTES=30
POLL_START_HOUR=6
POLL_END_HOUR=23
FORWARD_WINDOW_DAYS=5
MIN_GOALIES=1
MIN_PLAYERS_REGISTERED=10
PLAYER_SPOTS_URGENT=4
```

Save and exit (`Ctrl+X`, `Y`, `Enter`).

### 2.4 Restart Agent with Updated Config

```bash
pm2 restart adult-hockey-agent
```

## Part 3: Verification

### 3.1 Check Agent Status

```bash
# View PM2 status
pm2 status

# Should show:
# ┌────┬────────────────────┬──────────┬──────┬───────────┬──────────┬──────────┐
# │ id │ name               │ mode     │ ↺    │ status    │ cpu      │ memory   │
# ├────┼────────────────────┼──────────┼──────┼───────────┼──────────┼──────────┤
# │ 0  │ adult-hockey-agent │ fork     │ 0    │ online    │ 0%       │ 50.0mb   │
# └────┴────────────────────┴──────────┴──────┴───────────┴──────────┴──────────┘

# View logs
pm2 logs adult-hockey-agent --lines 50

# Should see:
# 🏒 Adult Hockey Agent starting...
# 📋 Config:
#    Poll interval: 60 minutes
#    ...
# 🌐 Health endpoint available at http://localhost:3000/health
# ⏰ Running initial poll at ...
# ✓ Initial poll complete
# ✅ Agent running. Press Ctrl+C to stop.
```

### 3.2 Test Health Endpoint

```bash
# On the server
curl http://localhost:3000/health

# Should return:
# {"status":"ok","uptime":123.456,"lastPoll":"2026-02-17T12:00:00.000Z"}

# From your local machine
curl http://YOUR_DROPLET_IP:3000/health
```

### 3.3 Test Reboot Persistence

```bash
# Reboot the server
sudo reboot

# Wait 60 seconds, then SSH back in
ssh adulthockey@YOUR_DROPLET_IP

# Check if agent auto-started
pm2 status

# Should show agent running with uptime < 1 minute
```

### 3.4 Check Slack Notifications

The agent will send a notification to Slack when it finds a session meeting alert criteria. To test:

1. Wait for the next poll (check logs for timing)
2. Look for alerts in your Slack channel
3. If no sessions meet criteria, you won't get alerts (this is expected)

To force a test notification:
```bash
# Send a test message to your webhook
curl -X POST -H 'Content-Type: application/json' \
  -d '{"text":"Test from hockey agent"}' \
  YOUR_SLACK_WEBHOOK_URL
```

## Part 4: Ongoing Maintenance

### 4.1 Update Agent (Deploy New Code)

```bash
# SSH into server
ssh hockey@YOUR_DROPLET_IP
cd ~/adult-hockey-agent

# Make deploy script executable (first time only)
chmod +x scripts/deploy.sh

# Run deployment
./scripts/deploy.sh
```

This will:
- Pull latest code from GitHub
- Install updated dependencies
- Rebuild TypeScript
- Restart PM2 process

### 4.2 Monitor Logs

```bash
# Tail logs in real-time
pm2 logs adult-hockey-agent

# View last 100 lines
pm2 logs adult-hockey-agent --lines 100

# View error logs only
pm2 logs adult-hockey-agent --err

# Clear logs
pm2 flush
```

### 4.3 Restart Agent

```bash
# Restart process
pm2 restart adult-hockey-agent

# Stop process
pm2 stop adult-hockey-agent

# Start process
pm2 start adult-hockey-agent

# Delete process from PM2
pm2 delete adult-hockey-agent

# Re-add process (if deleted)
pm2 start ecosystem.config.cjs
pm2 save
```

### 4.4 View Process Details

```bash
# Detailed status
pm2 show adult-hockey-agent

# Real-time monitoring dashboard
pm2 monit

# Exit monit with Ctrl+C
```

### 4.5 Update Environment Variables

```bash
# Edit .env
nano .env

# Save and exit, then restart
pm2 restart adult-hockey-agent
```

### 4.6 View State File

```bash
# View current state
cat data/state.json | jq .

# Clear state (forces re-evaluation)
rm data/state.json
pm2 restart adult-hockey-agent
```

### 4.7 Disk Space Management

```bash
# Check disk usage
df -h

# Check log file sizes
du -h logs/

# Rotate logs if they get large
pm2 flush
```

## Part 5: Troubleshooting

### Agent Won't Start

```bash
# Check PM2 logs for errors
pm2 logs adult-hockey-agent --err

# Common issues:
# - Missing .env file: Copy from .env.example
# - Invalid SLACK_WEBHOOK_URL: Check URL format
# - Port already in use: Change PORT in .env
# - Out of memory: Check with `free -h`, restart server if needed
```

### No Slack Notifications

```bash
# 1. Check SLACK_WEBHOOK_URL is set
cat .env | grep SLACK_WEBHOOK_URL

# 2. Test webhook manually
curl -X POST -H 'Content-Type: application/json' \
  -d '{"text":"Test"}' YOUR_SLACK_WEBHOOK_URL

# 3. Check agent is running and polling
pm2 logs adult-hockey-agent --lines 50

# 4. Verify you're within active hours (6am-11pm ET by default)
date -u  # Check current UTC time
# 6am ET = 11am UTC, 11pm ET = 4am UTC next day
```

### Health Endpoint Returns 404

```bash
# Check server is running
pm2 status

# Check port binding
sudo netstat -tulpn | grep :3000

# Check firewall allows port 3000
sudo ufw status  # If using ufw
# Or check DigitalOcean firewall in dashboard

# Test locally first
curl http://localhost:3000/health
```

### Agent Crashes Frequently

```bash
# Check restart count
pm2 status  # Look at ↺ column

# View error logs
pm2 logs adult-hockey-agent --err

# Check memory usage
free -h
pm2 monit

# Common issues:
# - Playwright out of memory: Already set to 500MB max in ecosystem.config.cjs
# - Network errors: Check DASH API is accessible
# - Invalid state file: Delete data/state.json and restart
```

### Can't SSH In

```bash
# From local machine, check SSH connection
ssh -v hockey@YOUR_DROPLET_IP

# If connection refused:
# - Check droplet is running in DigitalOcean dashboard
# - Check firewall allows SSH (port 22)
# - Reboot droplet from DigitalOcean dashboard

# If authentication fails:
# - Verify SSH key: ssh-add -l
# - Try root user: ssh root@YOUR_DROPLET_IP
# - Use DigitalOcean console access from dashboard
```

## Part 6: Optional Enhancements

### 6.1 Setup Nginx Reverse Proxy

See `docs/nginx.conf` for a complete nginx configuration. This is useful for:
- SSL/HTTPS support (Let's Encrypt)
- Multiple services on same server
- Better logging and rate limiting

**Installation**:
```bash
sudo apt install nginx
sudo cp docs/nginx.conf /etc/nginx/sites-available/adult-hockey-agent
sudo ln -s /etc/nginx/sites-available/adult-hockey-agent /etc/nginx/sites-enabled/
sudo nginx -t  # Test config
sudo systemctl restart nginx
```

### 6.2 Setup SSL with Let's Encrypt

```bash
# Install certbot
sudo apt install certbot python3-certbot-nginx

# Get certificate (requires domain name pointing to droplet)
sudo certbot --nginx -d yourdomain.com

# Auto-renewal is configured automatically
sudo certbot renew --dry-run  # Test renewal
```

### 6.3 Setup Log Rotation

PM2 has built-in log rotation, but for more control:

```bash
# Install pm2-logrotate module
pm2 install pm2-logrotate

# Configure (optional)
pm2 set pm2-logrotate:max_size 10M
pm2 set pm2-logrotate:retain 7
pm2 set pm2-logrotate:compress true
```

### 6.4 Setup Monitoring Alerts

```bash
# Install PM2 Plus (free for 1 server)
pm2 plus

# Follow on-screen instructions to link to PM2.io dashboard
# You'll get email alerts for crashes, high CPU, etc.
```

### 6.5 Setup Automated Backups

```bash
# Create backup script
cat > ~/backup-adult-hockey-agent.sh << 'EOF'
#!/bin/bash
BACKUP_DIR=~/backups
mkdir -p $BACKUP_DIR
DATE=$(date +%Y%m%d-%H%M%S)
tar -czf $BACKUP_DIR/adult-hockey-agent-$DATE.tar.gz \
  ~/adult-hockey-agent/data \
  ~/adult-hockey-agent/.env
# Keep only last 7 backups
ls -t $BACKUP_DIR/adult-hockey-agent-*.tar.gz | tail -n +8 | xargs rm -f
EOF

chmod +x ~/backup-adult-hockey-agent.sh

# Add to crontab (daily at 2am)
crontab -e
# Add this line:
# 0 2 * * * /home/adulthockey/backup-adult-hockey-agent.sh
```

## Part 7: Security Hardening

### 7.1 Disable Root SSH

```bash
# Edit SSH config
sudo nano /etc/ssh/sshd_config

# Set:
PermitRootLogin no

# Restart SSH
sudo systemctl restart sshd
```

### 7.2 Setup Fail2Ban

```bash
# Install fail2ban
sudo apt install fail2ban

# Enable for SSH
sudo systemctl enable fail2ban
sudo systemctl start fail2ban

# Check status
sudo fail2ban-client status sshd
```

### 7.3 Setup UFW Firewall (Alternative to DigitalOcean Firewall)

```bash
# Enable UFW
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow 3000/tcp  # Or restrict to Slack IPs
sudo ufw enable

# Check status
sudo ufw status verbose
```

### 7.4 Keep System Updated

```bash
# Update packages
sudo apt update && sudo apt upgrade -y

# Setup automatic security updates
sudo apt install unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

## Summary Checklist

### Initial Deployment
- [ ] Create DigitalOcean droplet (Ubuntu 24.04, $6/mo)
- [ ] Configure firewall (SSH, HTTP, HTTPS, 3000)
- [ ] SSH in as root and create `hockey` user
- [ ] Clone repository
- [ ] Run `scripts/setup-server.sh`
- [ ] Edit `.env` and add `SLACK_WEBHOOK_URL`
- [ ] Restart agent: `pm2 restart adult-hockey-agent`
- [ ] Verify status: `pm2 status`
- [ ] Test health endpoint: `curl http://localhost:3000/health`
- [ ] Test reboot: `sudo reboot` and verify auto-start
- [ ] Test Slack notifications (wait for next poll)

### Ongoing Maintenance
- [ ] Update code: `./scripts/deploy.sh`
- [ ] Monitor logs: `pm2 logs adult-hockey-agent`
- [ ] Check status: `pm2 status`
- [ ] View state: `cat data/state.json | jq .`

### Optional
- [ ] Setup nginx reverse proxy
- [ ] Setup SSL with Let's Encrypt
- [ ] Install pm2-logrotate
- [ ] Setup PM2 Plus monitoring
- [ ] Setup automated backups
- [ ] Harden security (disable root SSH, fail2ban, ufw)

## Support

For issues or questions:
- Check logs: `pm2 logs adult-hockey-agent`
- Review troubleshooting section above
- Check GitHub issues: https://github.com/hunterleaman/adult-hockey-agent/issues
- Review project docs: `docs/SPEC.md`, `CLAUDE.md`
