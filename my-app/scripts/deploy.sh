#!/bin/bash
set -e

APP_DIR="/home/ec2-user/app"

# Kill existing process if running
pkill -f "python3 app.py" || true

# Pull latest code
mkdir -p $APP_DIR
cd $APP_DIR
git clone https://github.com/YOUR_ORG/YOUR_REPO.git . 2>/dev/null || git pull

# Install dependencies
pip3 install flask --quiet

# Start app in background
nohup sudo python3 app/app.py > /var/log/app.log 2>&1 &
echo "App started. PID: $!"