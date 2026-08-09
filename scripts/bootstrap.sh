#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required but was not found in PATH."
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not running. Start Docker Desktop and retry."
  exit 1
fi

if [ ! -d .git ]; then
  echo "Initializing local git repository..."
  git init -b main
  git add .
  git commit -m "Initial local Jenkins demo"
fi

echo "Building and starting Jenkins..."
docker compose up -d --build

echo "Waiting for Jenkins to become ready..."
for _ in $(seq 1 60); do
  if curl -sf "http://localhost:8080/login" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done

echo ""
echo "Jenkins is starting at http://localhost:8080"
echo ""
echo "Initial admin password:"
docker compose exec jenkins cat /var/jenkins_home/secrets/initialAdminPassword || true
echo ""
echo "Next steps:"
echo "  1. Open http://localhost:8080 and complete the setup wizard."
echo "  2. Create a Pipeline job using Pipeline script from SCM."
echo "  3. Git repository URL: file:///workspace"
echo "  4. Script Path: Jenkinsfile"
echo "  5. Branch: main"
echo ""
echo "See README.md for full instructions."
