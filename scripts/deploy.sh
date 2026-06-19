#!/bin/bash
set -e

APP_DIR="/home/ec2-user/app"

# Install dependencies
sudo yum install -y python3 python3-pip git
sudo pip3 install flask

# Kill existing process if running
sudo pkill -f "python3" || true
sleep 2

# Clone or pull latest code
mkdir -p $APP_DIR
cd $APP_DIR

if [ -d ".git" ]; then
    git pull
else
    git clone https://github.com/mamir08aws-cmyk/jenkins-aws.git .
fi

# Verify app.py exists
ls -la my-app/app/app.py

# Start Flask app on port 80 with sudo using full python path
nohup sudo /usr/bin/python3 $APP_DIR/my-app/app/app.py > /var/log/app.log 2>&1 &
echo "App started. PID: $!"
sleep 3

# Confirm it's running
sudo ps aux | grep python3 | grep -v grep
echo "App log:"
sudo tail -5 /var/log/app.log
