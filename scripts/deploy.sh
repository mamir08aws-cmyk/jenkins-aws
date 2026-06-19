#!/bin/bash

APP_DIR="/home/ec2-user/app"

# Install dependencies
sudo yum install -y python3 python3-pip git
sudo pip3 install flask

# Kill existing process
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

# Create log file with correct permissions
sudo touch /var/log/app.log
sudo chmod 666 /var/log/app.log

# Start Flask app
nohup sudo /usr/bin/python3 $APP_DIR/my-app/app/app.py > /var/log/app.log 2>&1 &
echo "App started. PID: $!"
sleep 5

# Show status
echo "=== Process check ==="
ps aux | grep python3 | grep -v grep || echo "WARNING: python3 not running"

echo "=== App log ==="
cat /var/log/app.log

echo "=== Port check ==="
sudo netstat -tlnp | grep :80 || echo "WARNING: nothing on port 80"
