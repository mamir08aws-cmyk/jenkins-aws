# Migration Guide: From Flask to HIBP Service

## What Changed

The `jenkins-aws` repository has been upgraded from a basic Flask deployment to a production-grade **HIBP (Have I Been Pwned) Password Validation Service**.

### Old System (Removed)
- Simple Flask web server on port 80
- Manual EC2 deployment via Jenkins
- No SSL/TLS encryption
- Basic application hosting

### New System (Deployed)
- Node.js password validation API
- HTTPS (TLS 1.2/1.3) via nginx
- 2 billion+ breach hash database
- Weak password detection
- Binary search engine (10-20ms per lookup)
- Systemd service management
- IP-based access control
- PingOne DaVinci integration ready

## File Changes

### New Files Added
- `scripts/hibp_deploy.sh` — Main deployment automation script (66KB)
- `HIBP_DEPLOYMENT.md` — Complete deployment documentation
- `MIGRATION.md` — This file

### Modified Files
- `scripts/deploy.sh` — Now points to new system

### Removed/Unchanged
- `my-app/` — Legacy Flask application (unchanged)
- `Jenkinsfile` — Unchanged
- Other configs — Unchanged

## Migration Path

### For New Deployments
```bash
cd scripts/
./hibp_deploy.sh prereqs    # ~10 min: install prerequisites
./hibp_deploy.sh            # Wizard + full deploy
```

Timeline:
- Prerequisites: ~10 minutes
- Download (if first time): **4-8 hours** (run overnight)
- Index build (if first time): **30-90 minutes**
- Install & start: ~5 minutes

### For Existing Deployments
If you're currently running the old Flask app:

1. **Keep it running** — The new HIBP service runs on different ports (3001 internally, 443 for nginx)
2. **Run new deployment** — Won't conflict with existing setup
3. **Test both** — Verify both systems work
4. **Switch DNS/routing** — Update load balancer to point to new service
5. **Decommission old** — Remove Flask app when ready

## Key Differences

| Aspect | Old | New |
|--------|-----|-----|
| **Language** | Python (Flask) | Node.js |
| **Port** | 80 (HTTP) | 3001 (internal), 443 (HTTPS) |
| **Encryption** | None | TLS 1.2/1.3 |
| **Data** | Application code | 88GB breach hashes + 16GB index |
| **User** | root | hibpuser (non-root) |
| **Service Manager** | Manual/Jenkins | systemd |
| **Auto-restart** | No | Yes (10s delay) |
| **Monitoring** | Manual checks | /health endpoint |

## API Endpoints

### New HIBP Service
```
POST /check       → {pwned: bool, count: int, ms: float}
POST /checkweak   → {weak: bool, category: string}
GET  /health      → {status: "ok", totalLines: int, ...}
```

### Old Flask Service
```
[Custom endpoints defined in my-app/]
```

## Data Storage

New service requires:
- **88GB** for HIBP hash file (`pwnedpasswords.txt`)
- **16GB** for binary search index (`pwnedpasswords.idx`)
- **4MB** for weak password list (`weak_passwords.txt`)
- Default location: `/apps/hibp/hibp-data/`

## Configuration

The deployment wizard asks for:

1. **Data path** — Where to store the massive hash/index files
2. **Service path** — Where to run the Node.js service from
3. **API port** — Node.js port (default: 3001)
4. **Service user** — Non-root account (default: hibpuser)
5. **PingOne IPs** — IP ranges that can call /check and /checkweak
6. **Admin IP** — Your office/VPN IP for testing

Saved to: `hibp_deploy.config`

## Security Changes

### Old System
- Ran as root
- HTTP only (no encryption)
- No access controls

### New System
- Runs as non-root user (`hibpuser`)
- HTTPS only (TLS 1.2/1.3)
- IP-based access control (firewalld + nginx)
- Weak password list server-side only
- No passwords or hashes transmitted

## Rollback Plan

If you need to revert to the old Flask system:

```bash
# Old Flask still exists in my-app/
cd my-app
python3 app/app.py

# Or via the old deployment:
cd scripts
./deploy.sh  # Will show message about new system
```

## Getting Help

### Deployment Issues
```bash
./hibp_deploy.sh logs      # View service logs
./hibp_deploy.sh status    # Check service status
./hibp_deploy.sh test      # Run quick tests
```

### Configuration
```bash
./hibp_deploy.sh config    # Re-run configuration wizard
# Edit manually: scripts/hibp_deploy.config
```

### Documentation
- `HIBP_DEPLOYMENT.md` — Complete deployment guide
- `hibp_deploy.sh --help` — Script help

### Common Issues

**"Address already in use"**
```bash
sudo lsof -i :443
sudo lsof -i :3001
```

**"Connection refused"**
```bash
sudo systemctl status hibp
sudo systemctl status nginx
```

**"Certificate verify failed"**
```bash
# Accept self-signed cert in browser:
curl -sk https://YOUR_IP/health
```

## Next Steps

1. **Read** `HIBP_DEPLOYMENT.md` for complete details
2. **Run** `./hibp_deploy.sh prereqs` to install prerequisites
3. **Deploy** `./hibp_deploy.sh` for full setup
4. **Test** `./hibp_deploy.sh test` to verify endpoints
5. **Integrate** with PingOne DaVinci

## Support Resources

- **HIBP Data**: https://haveibeenpwned.com/Passwords
- **Downloader**: https://github.com/HaveIBeenPwned/PwnedPasswordsDownloader
- **PingOne Docs**: https://documentation.pingidentity.com/
- **Node.js Docs**: https://nodejs.org/docs/

---

**Migration completed**: June 2026
**Old system**: Flask app still available in `my-app/`
**New system**: HIBP service via `hibp_deploy.sh`
