# HIBP Jenkins Integration Guide

## Overview

The updated Jenkinsfile deploys the HIBP Password Validation Service entirely through Jenkins. It handles EC2 provisioning, HIBP deployment, health checks, and endpoint validation.

## Pipeline Stages

### 1. **Checkout**
Clones the repository from GitHub.

### 2. **Provision EC2 with Terraform**
Launches RHEL/CentOS EC2 instance with:
- Sufficient disk space (120GB+ free)
- Security group rules for ports 443, 3001
- Auto-assigns public IP

### 3. **Wait for EC2 to be ready**
Waits 60 seconds for instance to fully initialize.

### 4. **Deploy HIBP Service via Jenkins**
Executes non-interactive deployment:
- Copies `hibp_deploy.sh` and `hibp_jenkins_deploy.sh` to EC2
- Runs configuration (paths, IPs, settings)
- Executes all deployment stages via `hibp_jenkins_deploy.sh` wrapper
- Handles long-running operations gracefully

### 5. **Validate - HTTPS Health Check**
Tests HTTPS `/health` endpoint (20 attempts, 5-second intervals):
- Ignores self-signed certificate warning
- Retries up to 100 seconds
- Confirms service is running

### 6. **Validate - HIBP Endpoints**
Tests all three endpoints:
- `POST /check` — Breach detection
- `POST /checkweak` — Weak password detection
- `GET /health` — Monitoring

### 7. **Test Summary**
Prints success report with API endpoints and admin commands.

## Build Parameters

When running the pipeline, configure these parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `SKIP_DOWNLOAD` | `true` | Skip 88GB download (4-8 hours) |
| `SKIP_INDEX` | `true` | Skip 16GB index build (30-90 min) |
| `HIBP_PINGONE_IPS` | `3.235.0.0/16` | PingOne outbound IP ranges |
| `HIBP_ADMIN_IP` | (blank) | Your office/VPN IP for testing |

### Usage Examples

**Testing Only (Recommended for First Run):**
```
SKIP_DOWNLOAD=true
SKIP_INDEX=true
```
Runs in ~5-10 minutes. Download/index skipped for later.

**Full Deployment with Download:**
```
SKIP_DOWNLOAD=false
SKIP_INDEX=false
```
⚠️ **Takes 5-10 hours!** (mostly download/index time)
Likely to timeout in Jenkins. Better to run manually on EC2 in `screen`.

**Production with PingOne IPs:**
```
SKIP_DOWNLOAD=true
SKIP_INDEX=true
HIBP_PINGONE_IPS=3.235.0.0/16,52.206.0.0/16
HIBP_ADMIN_IP=203.0.113.45/32
```

## How It Works

### Jenkins Script Flow

```
1. Terraform provisions EC2 instance
   ↓
2. Jenkins SSHs to EC2
   ↓
3. Copies scripts to EC2
   ↓
4. Runs hibp_jenkins_deploy.sh (wrapper script)
   ↓
5. Wrapper loads config from ENV vars
   ↓
6. Calls hibp_deploy.sh stages (prereqs, dirs, server, nginx, etc.)
   ↓
7. Returns to Jenkins
   ↓
8. Jenkins validates endpoints
   ↓
9. Reports success/failure
```

### Non-Interactive Configuration

Instead of the interactive wizard, the deployment uses ENV variables:

```bash
export HIBP_DATA_DIR="/apps/hibp/hibp-data"
export HIBP_SERVICE_DIR="/apps/hibp/hibp-service"
export HIBP_PORT="3001"
export HIBP_PINGONE_IPS="3.235.0.0/16"
export HIBP_ADMIN_IP="203.0.113.45/32"
export HIBP_SKIP_DOWNLOAD="true"
export HIBP_SKIP_INDEX="true"

./hibp_jenkins_deploy.sh
```

Configuration is saved to `hibp_deploy.config` for future manual runs.

## Environment Variables

All HIBP configuration is controlled by ENV variables set by the Jenkinsfile:

| Variable | Default | Purpose |
|----------|---------|---------|
| `HIBP_DATA_DIR` | `/apps/hibp/hibp-data` | Hash file location |
| `HIBP_SERVICE_DIR` | `/apps/hibp/hibp-service` | Service installation |
| `HIBP_PORT` | `3001` | Internal Node.js port |
| `HIBP_SERVICE_USER` | `hibpuser` | Non-root service account |
| `HIBP_DOTNET_DIR` | `/apps/hibp/dotnet9` | .NET SDK location |
| `HIBP_PARALLELISM` | `16` | Download threads |
| `HIBP_SKIP_DOWNLOAD` | `true` | Skip 4-8 hour download |
| `HIBP_SKIP_INDEX` | `true` | Skip 30-90 min index build |
| `HIBP_PINGONE_IPS` | `3.235.0.0/16` | IP access restrictions |
| `HIBP_ADMIN_IP` | (blank) | Admin test IP |

## Jenkins Requirements

### Credentials
- `aws-credentials` — AWS access key/secret for Terraform
- `ssh-ec2-key` — SSH private key for EC2 access

### SSH Access
Jenkins machine must be able to SSH to EC2 instance (security group rules).

### Disk Space (on EC2)
- 120GB+ free space required for download + index build
- Terraform automatically sizes instance appropriately

### Timeout Settings
- Stage timeout: Recommend `60 minutes` for full deployment
- Individual stage timeout: `30 minutes` for downloads

To set in Jenkins:
```groovy
options {
    timeout(time: 60, unit: 'MINUTES')
}
```

## Testing the Pipeline

### First Run (Recommended)
```
1. Create new Jenkins job from this Jenkinsfile
2. Run with defaults (SKIP_DOWNLOAD=true, SKIP_INDEX=true)
3. Should complete in ~5-10 minutes
4. Verify endpoints respond (check build logs)
```

### Full Deployment (Manual EC2 Later)
```
1. Run Jenkins pipeline with SKIP_DOWNLOAD=false, SKIP_INDEX=false
2. Pipeline will attempt download/index but likely timeout
3. SSH to EC2 and run manually in screen:
   screen -S hibp
   ./hibp_deploy.sh download    # 4-8 hours
   ./hibp_deploy.sh build-index # 30-90 minutes
   screen -r hibp              # check progress anytime
```

### Endpoint Testing in Jenkins Logs

Build logs show test results:

```
Testing /check endpoint (breach detection)...
Response: {"pwned":true,"count":123456,"hash":"5BAA61E4...","ms":0.45}
✓ /check endpoint working

Testing /checkweak endpoint (weak password detection)...
Response: {"weak":true,"category":"common word","word":"welcome"}
✓ /checkweak endpoint working

Testing /health endpoint...
Response (truncated): {"status":"ok","totalLines":2048908128,"uptime":45.3...
✓ /health endpoint working

✓ All endpoints validated successfully
```

## Post-Deployment Admin Tasks

After successful Jenkins deployment:

```bash
# SSH to EC2
ssh -i key.pem ec2-user@INSTANCE_IP

# Check service status
./hibp_deploy.sh status

# View logs
./hibp_deploy.sh logs

# Add more weak words
nano /apps/hibp/hibp-data/weak_passwords.txt

# If download/index needed:
screen -S hibp
./hibp_deploy.sh download
# Ctrl+A D to detach
```

## Troubleshooting Jenkins Deployment

### "Connection refused" on health check
- Instance may still be initializing
- Jenkins retries up to 20 times (100 seconds total)
- If still failing, check security group allows port 443

### "Download timed out"
- **Expected behavior** — 4-8 hour download exceeds typical Jenkins timeout
- Run manually on EC2: `./hibp_deploy.sh download`
- Or increase Jenkins job timeout to `> 480 minutes` (8 hours)

### "Insufficient disk space"
- Terraform didn't provision enough space
- Edit `infra/main.tf` to increase `root_block_device.volume_size`

### "SSH key not found"
- Jenkins credential `ssh-ec2-key` not configured
- Add SSH private key to Jenkins credentials manager
- Use credential ID: `ssh-ec2-key`

### "AWS credentials error"
- Jenkins credential `aws-credentials` not configured
- Add AWS access key/secret to Jenkins credentials manager
- Use credential ID: `aws-credentials`

## Monitoring After Deployment

### Jenkins Log Indicators

**Success:**
```
✓ Health check passed!
✓ /check endpoint working
✓ /checkweak endpoint working
✓ All endpoints validated successfully
✓ Deployment successful!
```

**Warnings (OK):**
```
⚠ Skipping HIBP download (HIBP_SKIP_DOWNLOAD=true)
⚠ Download failed or timed out
⚠ This is expected in Jenkins (long-running job)
```

**Errors (Investigate):**
```
✗ /check endpoint FAILED
✗ Health check failed after 100 seconds
✗ /checkweak endpoint FAILED
✗ Pipeline failed
```

## Next Steps

1. **Configure Jenkins credentials** — AWS + SSH key
2. **Create pipeline job** — Point to this Jenkinsfile
3. **Run first build** — With SKIP_DOWNLOAD/INDEX=true
4. **Verify endpoints** — Check test results in logs
5. **Optional: Run manual download** — On EC2 if needed

---

**For complete HIBP documentation:** See `HIBP_DEPLOYMENT.md`
**For manual deployment:** Use `scripts/hibp_deploy.sh`
**For Jenkins wrapper:** See `scripts/hibp_jenkins_deploy.sh`
