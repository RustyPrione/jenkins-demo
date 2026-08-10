pipeline {
    agent any

    environment {
        APP_NAME = 'jenkins-demo'
        DOCKERFILE_PATH = 'app/Dockerfile'
        BUILD_CONTEXT = 'app'
        DOCKER_IMAGE_NAME = "local/${APP_NAME}"
        DEPLOY_CONTAINER_NAME = 'jenkins-demo-app'
        DEPLOY_HOST_PORT = '8081'
        APP_URL = "http://localhost:${DEPLOY_HOST_PORT}"
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
                    echo "Deploy URL: ${APP_URL}"
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

        stage('Deploy Local') {
            steps {
                script {
                    echo "Deploying ${env.DOCKER_FULL_IMAGE_NAME} to ${APP_URL}"

                    sh """
                        set -e

                        echo "Stopping previous container if it exists..."
                        ${DOCKER_BIN} rm -f ${DEPLOY_CONTAINER_NAME} 2>/dev/null || true

                        echo "Starting container on port ${DEPLOY_HOST_PORT}..."
                        ${DOCKER_BIN} run -d \
                            --name ${DEPLOY_CONTAINER_NAME} \
                            -p ${DEPLOY_HOST_PORT}:80 \
                            --restart unless-stopped \
                            --label commit=${env.COMMIT_SHA} \
                            ${env.DOCKER_FULL_IMAGE_NAME}

                        echo "Waiting for the app to become reachable..."
                        READY=false
                        for attempt in \$(seq 1 30); do
                            if ${DOCKER_BIN} inspect -f '{{.State.Running}}' ${DEPLOY_CONTAINER_NAME} 2>/dev/null | grep -q true; then
                                if ${DOCKER_BIN} exec ${DEPLOY_CONTAINER_NAME} wget -q -O- http://127.0.0.1/ | grep -q 'Jenkins Demo App'; then
                                    READY=true
                                    break
                                fi
                            fi
                            sleep 2
                        done

                        if [ "\$READY" != true ]; then
                            echo "Deployment failed: app did not become healthy in time."
                            ${DOCKER_BIN} logs ${DEPLOY_CONTAINER_NAME} || true
                            exit 1
                        fi

                        echo "Container is running:"
                        ${DOCKER_BIN} ps --filter name=${DEPLOY_CONTAINER_NAME}
                        echo ""
                        echo "Open the deployed app at ${APP_URL}"
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
                echo "App URL: ${APP_URL}"
                echo "Build URL: ${env.BUILD_URL}"
                echo '==================================================='
            }
        }
    }
}
