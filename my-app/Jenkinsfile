pipeline {
    agent any

    environment {
        AWS_REGION = 'us-east-1'
        TF_DIR     = 'infra'
        REPO_URL   = 'https://github.com/mamir08aws-cmyk/jenkins-aws.git'
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
                    echo "Waiting 45 seconds for EC2 to initialize..."
                    sleep 45
                '''
            }
        }

        stage('Deploy App via SSH') {
            steps {
                sshagent(['ssh-ec2-key']) {
                    sh """
                        ssh -o StrictHostKeyChecking=no ec2-user@${EC2_IP} \
                            'bash -s' < scripts/deploy.sh
                    """
                }
            }
        }

        stage('Validate - Health Check') {
            steps {
                sh """
                    echo "Checking app health at http://${EC2_IP}/health"
                    for i in \$(seq 1 12); do
                        STATUS=\$(curl -s -o /dev/null -w "%{http_code}" \
                                  http://${EC2_IP}/health || true)
                        echo "Attempt \$i: HTTP \$STATUS"
                        if [ "\$STATUS" = "200" ]; then
                            echo "Health check passed!"
                            exit 0
                        fi
                        sleep 10
                    done
                    echo "Health check failed after 2 minutes."
                    exit 1
                """
            }
        }

        stage('Validate - Smoke Test') {
            steps {
                sh """
                    RESPONSE=\$(curl -sf http://${EC2_IP}/ || true)
                    echo "Home page response: \$RESPONSE"
                    echo "\$RESPONSE" | grep -q "Hello from Jenkins" && \
                        echo "Smoke test passed!" || \
                        (echo "Smoke test FAILED" && exit 1)
                """
            }
        }
    }

    post {
        success {
            echo "Deployment successful! App running at http://${EC2_IP}"
        }
        failure {
            echo "Pipeline failed — check logs above."
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