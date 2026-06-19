provider "aws" {
  region = "us-east-1"
}

# Key pair — upload your public key to AWS
resource "aws_key_pair" "deployer" {
  key_name   = "jenkins-deploy-key"
  public_key = file("/Users/mohammad.b.amir/.ssh/jenkins-deploy-key.pub")
}

# Security group — SSH + HTTP
resource "aws_security_group" "app_sg" {
  name        = "app-security-group"
  description = "Allow SSH and HTTP"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]   # Lock to your IP in production
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 instance
resource "aws_instance" "app_server" {
  ami                    = "ami-0c02fb55956c7d316"  # Amazon Linux 2 us-east-1
  instance_type          = "t2.micro"
  key_name               = aws_key_pair.deployer.key_name
  vpc_security_group_ids = [aws_security_group.app_sg.id]

  # Bootstrap: install Python + pip on first boot
  user_data = <<-EOF
    #!/bin/bash
    yum update -y
    yum install -y python3 python3-pip git
    pip3 install flask
  EOF

  tags = {
    Name = "jenkins-deployed-app"
  }
}

# Export the public IP so Jenkins can SSH in
output "instance_public_ip" {
  value = aws_instance.app_server.public_ip
}