#!/bin/bash
set -e

APP_DIR="/home/ec2-user/app"

# Install dependencies directly (don't rely on user_data timing)
sudo yum install -y python3 python3-pip git
pip3 install flask --quiet

# Kill existing process if running
pkill -f "python3 app.py" || true

# Clone or pull latest code
mkdir -p $APP_DIR
cd $APP_DIR

if [ -d ".git" ]; then
    git pull
else
    git clone https://github.com/mamir08aws-cmyk/jenkins-aws.git .
fi

# Start app in background
nohup sudo python3 my-app/app/app.py > /var/log/app.log 2>&1 &
echo "App started. PID: $!"
