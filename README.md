# Local Jenkins Pipeline Demo

Run a minimal Jenkins pipeline locally with Docker. Jenkins orchestrates checkout, validation, and Docker image build using your host Docker daemon.

## Prerequisites

- Docker Desktop running on macOS
- Git

## Quick start

```bash
cd /Users/bitscrunch/Documents/photon-ai/jenkins-demo
chmod +x scripts/bootstrap.sh
./scripts/bootstrap.sh
```

The bootstrap script will:

1. Initialize a local git repository if one does not exist
2. Build and start Jenkins with Docker Compose
3. Print the initial admin unlock password

Jenkins UI: http://localhost:8080

## First-time Jenkins setup

1. Open http://localhost:8080
2. Paste the unlock password shown by `./scripts/bootstrap.sh`
3. Choose **Install suggested plugins** or continue with preinstalled plugins
4. Create an admin user

## Create the pipeline job

1. **New Item** → name it `jenkins-demo` → choose **Pipeline** → OK
2. Under **Pipeline**:
   - Definition: **Pipeline script from SCM**
   - SCM: **Git**
   - Repository URL: `file:///workspace`
   - Branch Specifier: `*/main`
   - Script Path: `Jenkinsfile`
3. Save, then click **Build Now**

The repository is mounted read-only into the Jenkins container at `/workspace`, so `file:///workspace` points at this project.

## Pipeline stages

| Stage | What it does |
|-------|----------------|
| Checkout | Checks out the repo and sets `COMMIT_SHA` |
| Environment Info | Prints branch, commit, and image name |
| Validate & Governance | Verifies Dockerfile exists and Docker CLI works |
| Build Docker Image | Builds `local/jenkins-demo:<commit-sha>` |

## Verify the build

After a successful run:

```bash
docker images | grep jenkins-demo
```

Run the built image:

```bash
docker run --rm -p 8081:80 local/jenkins-demo:<commit-sha>
```

Open http://localhost:8081

## Trigger pipeline after a local push

GitHub cannot reach `http://localhost:8080`, so pushes do not auto-trigger Jenkins.
Use the local trigger script to simulate a GitHub webhook or queue a build directly.

```bash
chmod +x scripts/trigger-pipeline.sh

# Simulate GitHub push webhook (requires GitHub / Branch Source plugin in Jenkins)
./scripts/trigger-pipeline.sh webhook

# Direct Jenkins API trigger (most reliable for local demo)
./scripts/trigger-pipeline.sh api

# Multibranch scan + branch build
./scripts/trigger-pipeline.sh scan
```

Optional environment variables:

```bash
export JENKINS_URL=http://localhost:8080
export JENKINS_JOB=job-demo
export JENKINS_BRANCH=main
export GITHUB_REPO=RustyPrione/jenkins-demo
export JENKINS_USER=admin
export JENKINS_API_TOKEN=your-api-token
```

Typical workflow:

```bash
git add .
git commit -m "Update demo app"
git push origin main
./scripts/trigger-pipeline.sh api
```

If Jenkins security is enabled, create an API token under **User → Configure → API Token**
and set `JENKINS_USER` and `JENKINS_API_TOKEN` before running the script.

## Useful commands

Start Jenkins:

```bash
docker compose up -d --build
```

Stop Jenkins:

```bash
docker compose down
```

View logs:

```bash
docker compose logs -f jenkins
```

Get unlock password again:

```bash
docker compose exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword
```

## Project layout

```
jenkins-demo/
├── app/                  # Sample app built by the pipeline
├── docker-compose.yml    # Jenkins stack
├── Dockerfile.jenkins    # Jenkins image with git + docker CLI
├── Jenkinsfile           # Declarative pipeline
├── plugins.txt           # Jenkins plugins installed at build time
└── scripts/bootstrap.sh  # One-command startup helper
```

## macOS notes

- Ensure Docker Desktop is running before starting Jenkins
- `/var/run/docker.sock` is mounted into the container so builds run on your host Docker engine
- The first `docker compose up --build` may take several minutes while plugins install

## Troubleshooting

**Pipeline cannot clone `file:///workspace`**

- Run `./scripts/bootstrap.sh` again to ensure the repo is initialized and committed
- Confirm the Jenkins container has the project mounted: `docker compose exec jenkins ls /workspace`

**Docker build fails inside Jenkins**

- Confirm Docker Desktop is running: `docker info`
- Rebuild the custom Jenkins image (required for Docker CLI inside Jenkins):

```bash
docker compose down
docker compose up -d --build
docker compose exec jenkins /usr/local/bin/docker --version
docker compose exec jenkins /usr/local/bin/docker info
```

- If `docker --version` fails inside the container, you are not running the custom `Dockerfile.jenkins` image
- Restart the stack: `docker compose down && docker compose up -d --build`

**Port 8080 already in use**

- Change the host port in `docker-compose.yml`, for example `"8081:8080"`

## Optional next steps

You can extend this demo later with:

- Local Docker registry (ACR substitute)
- SonarQube quality gate
- Trivy image scanning
- Mock GitOps Helm values update
