pipeline {
    agent any

    parameters {
        booleanParam(
            name: 'SKIP_DOWNLOAD',
            defaultValue: true,
            description: 'Skip HIBP download (88GB, 4-8 hours). Run manually later if needed.'
        )
        booleanParam(
            name: 'SKIP_INDEX',
            defaultValue: true,
            description: 'Skip index build (16GB, 30-90 min). Run manually later if needed.'
        )
        string(
            name: 'HIBP_PINGONE_IPS',
            defaultValue: '3.235.0.0/16',
            description: 'PingOne outbound IP ranges (comma-separated CIDR). Leave blank for testing.'
        )
        string(
            name: 'HIBP_ADMIN_IP',
            defaultValue: '',
            description: 'Your office/VPN IP for admin testing (e.g., 203.0.113.45/32). Optional.'
        )
    }

    environment {
        AWS_REGION              = 'us-east-1'
        TF_DIR                  = 'infra'
        REPO_URL                = 'https://github.com/mamir08aws-cmyk/jenkins-aws.git'
        // HIBP Configuration
        HIBP_DATA_DIR           = '/apps/hibp/hibp-data'
        HIBP_SERVICE_DIR        = '/apps/hibp/hibp-service'
        HIBP_PORT               = '3001'
        HIBP_SERVICE_USER       = 'hibpuser'
        HIBP_DOTNET_DIR         = '/apps/hibp/dotnet9'
        HIBP_PARALLELISM        = '16'
        // Pass parameters to script
        HIBP_SKIP_DOWNLOAD      = "${params.SKIP_DOWNLOAD}"
        HIBP_SKIP_INDEX         = "${params.SKIP_INDEX}"
        HIBP_PINGONE_IPS        = "${params.HIBP_PINGONE_IPS}"
        HIBP_ADMIN_IP           = "${params.HIBP_ADMIN_IP}"
    }

    stages {

        stage('Checkout') {
            steps {
                git branch: 'main', url: "${REPO_URL}"
            }
        }

        stage('Provision EC2 with Terraform') {
            steps {
                withCredentials([[
                    $class: 'AmazonWebServicesCredentialsBinding',
                    credentialsId: 'aws-credentials',
                    accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                    secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
                ]]) {
                    dir(env.TF_DIR) {
                        sh '''
                            terraform init -input=false
                            terraform plan -out=tfplan -input=false
                            terraform apply -auto-approve tfplan
                        '''
                        script {
                            env.EC2_IP = sh(
                                script: "terraform output -raw instance_public_ip",
                                returnStdout: true
                            ).trim()
                            echo "EC2 instance IP: ${env.EC2_IP}"
                        }
                    }
                }
            }
        }

        stage('Wait for EC2 to be ready') {
            steps {
                sh '''
                    echo "Waiting 60 seconds for EC2 to initialize..."
                    sleep 60
                '''
            }
        }

        stage('Deploy HIBP Service via Jenkins') {
            steps {
                sshagent(['ssh-ec2-key']) {
                    sh """
                        echo "========================================"
                        echo "HIBP Jenkins Deployment Configuration:"
                        echo "========================================"
                        echo "Data directory:   ${HIBP_DATA_DIR}"
                        echo "Service directory: ${HIBP_SERVICE_DIR}"
                        echo "API port:         ${HIBP_PORT}"
                        echo "Service user:     ${HIBP_SERVICE_USER}"
                        echo "Skip download:    ${HIBP_SKIP_DOWNLOAD}"
                        echo "Skip index:       ${HIBP_SKIP_INDEX}"
                        echo "PingOne IPs:      ${HIBP_PINGONE_IPS}"
                        echo "Admin IP:         ${HIBP_ADMIN_IP}"
                        echo "========================================"
                        echo ""

                        # Copy deployment scripts to EC2
                        scp -o StrictHostKeyChecking=no \
                            scripts/hibp_deploy.sh \
                            scripts/hibp_jenkins_deploy.sh \
                            ec2-user@${EC2_IP}:/tmp/

                        # Run deployment via Jenkins wrapper
                        ssh -o StrictHostKeyChecking=no ec2-user@${EC2_IP} << EOF
#!/bin/bash
set -e
export HIBP_DATA_DIR="${HIBP_DATA_DIR}"
export HIBP_SERVICE_DIR="${HIBP_SERVICE_DIR}"
export HIBP_PORT="${HIBP_PORT}"
export HIBP_SERVICE_USER="${HIBP_SERVICE_USER}"
export HIBP_DOTNET_DIR="${HIBP_DOTNET_DIR}"
export HIBP_PARALLELISM="${HIBP_PARALLELISM}"
export HIBP_SKIP_DOWNLOAD="${HIBP_SKIP_DOWNLOAD}"
export HIBP_SKIP_INDEX="${HIBP_SKIP_INDEX}"
export HIBP_PINGONE_IPS="${HIBP_PINGONE_IPS}"
export HIBP_ADMIN_IP="${HIBP_ADMIN_IP}"

cd /tmp
chmod +x hibp_jenkins_deploy.sh
./hibp_jenkins_deploy.sh
EOF
                    """
                }
            }
        }

        stage('Validate - HTTPS Health Check') {
            steps {
                sh """
                    echo "Checking HIBP health at https://${EC2_IP}/health (SSL verify disabled for self-signed cert)"
                    for i in \$(seq 1 20); do
                        STATUS=\$(curl -sk -o /dev/null -w "%{http_code}" \
                                  https://${EC2_IP}/health || true)
                        echo "Attempt \$i: HTTPS \$STATUS"
                        if [ "\$STATUS" = "200" ]; then
                            echo "✓ Health check passed!"
                            exit 0
                        fi
                        sleep 5
                    done
                    echo "✗ Health check failed after 100 seconds"
                    exit 1
                """
            }
        }

        stage('Validate - HIBP Endpoints') {
            steps {
                sh """
                    echo ""
                    echo "Testing /check endpoint (breach detection)..."
                    BREACH_TEST=\$(curl -sk -X POST https://${EC2_IP}/check \
                        -H 'Content-Type: application/json' \
                        -d '{"password":"password123"}' 2>/dev/null || echo '{}')
                    echo "Response: \$BREACH_TEST"
                    echo "\$BREACH_TEST" | grep -q '"pwned"' && \
                        echo "✓ /check endpoint working" || \
                        (echo "✗ /check endpoint FAILED" && exit 1)

                    echo ""
                    echo "Testing /checkweak endpoint (weak password detection)..."
                    WEAK_TEST=\$(curl -sk -X POST https://${EC2_IP}/checkweak \
                        -H 'Content-Type: application/json' \
                        -d '{"password":"welcome"}' 2>/dev/null || echo '{}')
                    echo "Response: \$WEAK_TEST"
                    echo "\$WEAK_TEST" | grep -q '"weak"' && \
                        echo "✓ /checkweak endpoint working" || \
                        (echo "✗ /checkweak endpoint FAILED" && exit 1)

                    echo ""
                    echo "Testing /health endpoint..."
                    HEALTH_TEST=\$(curl -sk https://${EC2_IP}/health 2>/dev/null || echo '{}')
                    echo "Response (truncated): \$(echo \$HEALTH_TEST | head -c 200)..."
                    echo "\$HEALTH_TEST" | grep -q '"status":"ok"' && \
                        echo "✓ /health endpoint working" || \
                        (echo "✗ /health endpoint FAILED" && exit 1)

                    echo ""
                    echo "✓ All endpoints validated successfully"
                """
            }
        }

        stage('Test Summary') {
            steps {
                sh """
                    echo ""
                    echo "╔════════════════════════════════════════════════════════════╗"
                    echo "║  HIBP Service Deployment Complete                         ║"
                    echo "╚════════════════════════════════════════════════════════════╝"
                    echo ""
                    echo "API Endpoints:"
                    echo "  HTTPS:  https://${EC2_IP}/check        (breach detection)"
                    echo "  HTTPS:  https://${EC2_IP}/checkweak    (weak password check)"
                    echo "  HTTPS:  https://${EC2_IP}/health       (monitoring)"
                    echo ""
                    echo "Admin Commands:"
                    echo "  Status: ssh ec2-user@${EC2_IP} 'bash scripts/hibp_deploy.sh status'"
                    echo "  Logs:   ssh ec2-user@${EC2_IP} 'bash scripts/hibp_deploy.sh logs'"
                    echo "  Tests:  ssh ec2-user@${EC2_IP} 'bash scripts/hibp_deploy.sh test'"
                    echo ""
                    echo "Notes:"
                    echo "  - Self-signed cert (browser will warn, that's OK)"
                    echo "  - Download/index: skipped in Jenkins (run manually if needed)"
                    echo "  - For long operations, SSH to EC2 and use: screen -S hibp"
                    echo ""
                """
            }
        }
    }

    post {
        success {
            sh '''
                echo ""
                echo "✓ Deployment successful!"
                echo "✓ HIBP service ready at https://${EC2_IP}"
                echo ""
            '''
        }
        failure {
            sh '''
                echo ""
                echo "✗ Pipeline failed — check logs above"
                echo "Common issues:"
                echo "  - Disk space: check EC2 has 120GB+ free"
                echo "  - Download timeout: normal for 4-8 hour operation (set SKIP_DOWNLOAD=true)"
                echo "  - Health check timeout: service may still be loading, try later"
                echo ""
            '''
            withCredentials([[
                $class: 'AmazonWebServicesCredentialsBinding',
                credentialsId: 'aws-credentials',
                accessKeyVariable: 'AWS_ACCESS_KEY_ID',
                secretKeyVariable: 'AWS_SECRET_ACCESS_KEY'
            ]]) {
                dir('infra') {
                    sh 'terraform destroy -auto-approve || true'
                }
            }
        }
    }
}