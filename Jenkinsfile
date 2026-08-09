pipeline {
    agent any

    environment {
        APP_NAME = 'jenkins-demo'
        DOCKERFILE_PATH = 'app/Dockerfile'
        BUILD_CONTEXT = 'app'
        DOCKER_IMAGE_NAME = "local/${APP_NAME}"
        DOCKER_HOST = 'unix:///var/run/docker.sock'
        DOCKER_BIN = '/usr/local/bin/docker'
        PATH = "/usr/local/bin:/usr/bin:/bin:${env.PATH}"
    }

    options {
        timestamps()
        timeout(time: 30, unit: 'MINUTES')
        disableConcurrentBuilds()
    }

    stages {
        stage('Checkout') {
            steps {
                script {
                    checkout scm

                    env.COMMIT_SHA = sh(
                        script: 'git rev-parse --short HEAD',
                        returnStdout: true
                    ).trim()

                    env.DOCKER_IMAGE_TAG = env.COMMIT_SHA
                    env.DOCKER_FULL_IMAGE_NAME = "${DOCKER_IMAGE_NAME}:${env.COMMIT_SHA}"

                    currentBuild.displayName = env.COMMIT_SHA

                    echo "Checkout successful - Commit SHA: ${env.COMMIT_SHA}"
                }
            }
        }

        stage('Environment Info') {
            steps {
                script {
                    echo '==================================================='
                    echo 'LOCAL JENKINS DEMO PIPELINE'
                    echo '==================================================='
                    echo "Branch Name: ${env.BRANCH_NAME ?: 'N/A'}"
                    echo "Commit SHA: ${env.COMMIT_SHA}"
                    echo "Docker Image: ${env.DOCKER_FULL_IMAGE_NAME}"
                    echo "Dockerfile Path: ${DOCKERFILE_PATH}"
                    echo "Build Context: ${BUILD_CONTEXT}"
                    echo '==================================================='
                }
            }
        }

        stage('Validate & Governance') {
            steps {
                script {
                    if (!fileExists("${DOCKERFILE_PATH}")) {
                        error "Dockerfile not found at ${DOCKERFILE_PATH}"
                    }
                    echo 'Dockerfile exists'

                    sh '''
                        set -e
                        DOCKER="${DOCKER_BIN:-docker}"

                        if [ ! -x "$DOCKER" ] && ! command -v docker > /dev/null 2>&1; then
                            echo "Docker CLI is not installed in the Jenkins container."
                            echo "Rebuild Jenkins with: docker compose up -d --build"
                            exit 1
                        fi

                        DOCKER="${DOCKER:-docker}"
                        echo "Docker host: ${DOCKER_HOST:-default}"
                        echo "Docker: $($DOCKER --version)"
                        $DOCKER info >/dev/null
                        echo "Docker daemon is reachable"
                    '''
                }
            }
        }

        stage('Build Docker Image') {
            steps {
                script {
                    echo "Building Docker image: ${env.DOCKER_FULL_IMAGE_NAME}"

                    sh """
                        ${DOCKER_BIN} build \
                            --build-arg BUILD_DATE=\$(date -u +'%Y-%m-%dT%H:%M:%SZ') \
                            --build-arg COMMIT_SHA=${env.COMMIT_SHA} \
                            --label branch=${env.BRANCH_NAME ?: 'local'} \
                            --label commit=${env.COMMIT_SHA} \
                            -t ${env.DOCKER_FULL_IMAGE_NAME} \
                            -f ${DOCKERFILE_PATH} \
                            ${BUILD_CONTEXT}
                    """

                    sh """
                        ${DOCKER_BIN} images --format "{{.Repository}}:{{.Tag}} {{.Size}}" | grep "${env.DOCKER_FULL_IMAGE_NAME}" || true
                    """
                }
            }
        }
    }

    post {
        always {
            script {
                def buildState = currentBuild.result ?: 'SUCCESS'
                echo ''
                echo '==================================================='
                echo "Pipeline finished with status: ${buildState}"
                echo "Image: ${env.DOCKER_FULL_IMAGE_NAME ?: 'N/A'}"
                echo "Build URL: ${env.BUILD_URL}"
                echo '==================================================='
            }
        }
    }
}
