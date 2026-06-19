# HIBP Password Validation Service - Deployment Guide

This repository now contains the **HIBP (Have I Been Pwned) In-House Password Validation Service**, a complete deployment system for a password breach checking API suitable for integration with PingOne DaVinci.

## What Gets Deployed

The `hibp_deploy.sh` script deploys:

- **POST /check** — Password breach checking against 2 billion+ HIBP hashes
- **POST /checkweak** — Server-side weak password detection
- **GET /health** — Monitoring and health check endpoint
- **Node.js API server** — Binary search engine for 88GB hash file
- **nginx HTTPS proxy** — TLS 1.2/1.3 encrypted endpoints
- **systemd service** — Auto-start on boot, auto-restart on crash
- **Firewall rules** — IP-based access control

## Quick Start

```bash
cd scripts/
chmod +x hibp_deploy.sh

# First time on a new RHEL/CentOS server:
./hibp_deploy.sh prereqs      # Check/install prerequisites (~10 min)
./hibp_deploy.sh              # Run wizard then full deploy
```

## Command Reference

### Initial Setup
- `./hibp_deploy.sh prereqs` — Install Node.js, Python, nginx, libicu, firewalld
- `./hibp_deploy.sh create-user` — Create dedicated hibpuser service account
- `./hibp_deploy.sh config` — Run configuration wizard (paths, IPs, settings)

### Deployment Steps (can run individually)
- `./hibp_deploy.sh download` — Download 88GB HIBP hash file (~4-8 hours)
- `./hibp_deploy.sh build-index` — Build 16GB binary search index (~30-90 min)
- `./hibp_deploy.sh install` — Install server, nginx, firewall, systemd

### Operations
- `./hibp_deploy.sh start` — Start services
- `./hibp_deploy.sh stop` — Stop services
- `./hibp_deploy.sh test` — Run quick tests
- `./hibp_deploy.sh status` — Show service status
- `./hibp_deploy.sh logs` — View service logs

## Timeline

| Step | Task | Duration |
|------|------|----------|
| 0 | Prerequisites install | ~10 minutes |
| 1-2 | Create dirs + weak word list | ~1 minute |
| 3-4 | Install .NET + HIBP downloader | ~5 minutes |
| 5 | Download 88GB hash file | **4-8 hours** (run overnight) |
| 6 | Build binary search index | **30-90 minutes** |
| 7-10 | Install server, nginx, firewall, systemd | ~5 minutes |
| 11-12 | Start service + tests | ~1 minute |

**Total**: ~5-10 hours (including download + index build)

## Important Prerequisites

- **OS**: RHEL 7+ or CentOS 7+ only (uses yum/dnf)
- **Disk**: 120GB+ free (`/apps/hibp` by default)
- **Internet**: One-time download from api.pwnedpasswords.com (4-8 hours)
- **Sudo**: Required for package installation and service management

## Configuration

The wizard asks for:

1. **Data directory** — Where to store the 88GB hash file and 16GB index (default: `/apps/hibp/hibp-data`)
2. **Service directory** — Where server runs from (default: `/apps/hibp/hibp-service`)
3. **API port** — Internal Node.js port (default: 3001)
4. **Service user** — Runs as this non-root account (default: `hibpuser`)
5. **PingOne IPs** — Restrict `/check` and `/checkweak` to these CIDR ranges
6. **Admin IP** — Your office/VPN IP for testing

Configuration saved to: `hibp_deploy.config` (same directory as script)

## Security Architecture

### Weak Password List
- **Server-side only** — words never exposed to browser
- **No transmission** — browser only sees: `{weak: true/false, category: "..."}`
- **Dynamic** — edit file to add/remove words, no restart needed
- **~50,000 words** across categories (company names, seasons, keyboard patterns, etc.)

### HIBP Hash File
- **Binary search** — finds any of 2 billion hashes in ~31 reads (~10-20ms)
- **Never transmitted** — only `pwned: true/false` returned
- **88GB file** — sorted, requires index for fast lookups
- **Supports 200GB+ files** — uses BigInt throughout (no 32-bit overflow)

### HTTPS/TLS
- **nginx proxy** — Required for DaVinci (HTTP from HTTPS pages blocked)
- **TLS 1.2/1.3** — Self-signed cert for testing, replace with real cert for production
- **CORS headers** — Allow cross-origin calls from auth.pingone.com

### IP Restrictions (Two-Layer)
1. **OS Level** — firewalld rules block non-allowed IPs at connection
2. **App Level** — nginx allow/deny rules second-check
3. **Open endpoints** — `/health` always accessible for monitoring

## Testing

After deployment:

```bash
# HIBP breach check
curl -sk -X POST https://YOUR_IP/check \
  -H 'Content-Type: application/json' \
  -d '{"password":"password123"}'
# Returns: {"pwned":true, "count":12345, "ms":0.3}

# Weak word check
curl -sk -X POST https://YOUR_IP/checkweak \
  -H 'Content-Type: application/json' \
  -d '{"password":"Welcome@123"}'
# Returns: {"weak":true, "category":"common word"}

# Health check
curl -sk https://YOUR_IP/health
# Returns: {"status":"ok", "totalLines":2048908128, "uptime":3600.5, ...}
```

## Logs

- **Main logs** — `sudo journalctl -u hibp -f`
- **Daily log files** — `/apps/hibp/hibp-service/logs/hibp-YYYY-MM-DD.log`
- **Error log** — `/apps/hibp/hibp-service/logs/hibp-error.log`

## Long-Running Operations (Run in screen)

For operations that take hours (download, index build):

```bash
# Start a detachable terminal session
screen -S hibp-download
./hibp_deploy.sh download
# Ctrl+A then D to detach

# Later, reconnect
screen -r hibp-download

# Or check without connecting
screen -ls
```

## Production Deployment

### Before Go-Live

1. **Replace self-signed cert**
   - AWS: Use ACM certificate + Application Load Balancer
   - Azure: Use App Gateway or Azure Front Door
   - Edit `/etc/nginx/conf.d/hibp.conf` with real cert paths

2. **Configure PingOne IPs**
   - Get IP ranges from: https://support.pingidentity.com
   - Re-run config: `./hibp_deploy.sh config`
   - Test: PingOne calls should work, your personal curl should get 403

3. **Remove self-signed cert warning**
   - Once real cert installed, DaVinci won't show security warning

4. **Lock down testing ports**
   - Remove firewall rule for port 3001
   - All external access should be via nginx port 443 only

### Disk Cleanup

The weak word list, index, and hash file are read-only after creation. To reclaim space:
- Remove hash file: `rm /apps/hibp/hibp-data/pwnedpasswords.txt` (but service won't work)
- Keep index and weak list (~16GB + 4MB total)

## Architecture

```
DaVinci (HTTPS)
    ↓
https://your-server/check (port 443)
    ↓
nginx proxy + TLS termination
    ↓ (HTTP)
Node.js app:3001
    ↓
Binary search engine
    ↓
88GB sorted hash file + 16GB byte-offset index
```

## Troubleshooting

### "Address already in use" on port 3001
```bash
sudo lsof -i :3001
sudo kill -9 <PID>
```

### "Certificate verify failed" errors
```bash
# Accept self-signed cert in browser first:
curl -sk https://YOUR_IP/health
# Then test from DaVinci
```

### "Mixed Content" error in DaVinci
- Means nginx HTTPS isn't working
- Check: `sudo systemctl status nginx`
- Check: `sudo nginx -t`
- Verify cert exists: `ls /etc/nginx/ssl/hibp.*`

### Performance slow (>500ms per lookup)
- Check disk speed: `dd if=/dev/zero of=/tmp/test bs=1M count=1000 oflag=direct`
- Check index build completed: `ls -lh /apps/hibp/hibp-data/pwnedpasswords.idx`
- Check RAM/CPU: `top` while requests are running

### Service won't start
```bash
sudo systemctl status hibp
sudo journalctl -u hibp -n 100
# Common: hash/index files missing or wrong paths
```

## Editing Weak Words

```bash
# Add new weak words
nano /apps/hibp/hibp-data/weak_passwords.txt

# Restart NOT needed — file is read fresh on every /checkweak request
# Test new words immediately:
curl -sk -X POST https://YOUR_IP/checkweak \
  -H 'Content-Type: application/json' \
  -d '{"password":"YourNewWeakWord@123"}'
```

## Support

For HIBP data source issues: https://haveibeenpwned.com/Passwords
For downloader issues: https://github.com/HaveIBeenPwned/PwnedPasswordsDownloader

---

**Last Updated**: June 2026
**Script Version**: 1.0
**Target OS**: RHEL 7+, CentOS 7+
