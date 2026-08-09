#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
JENKINS_JOB="${JENKINS_JOB:-job-demo}"
JENKINS_BRANCH="${JENKINS_BRANCH:-main}"
GITHUB_REPO="${GITHUB_REPO:-RustyPrione/jenkins-demo}"
WEBHOOK_PATH="${WEBHOOK_PATH:-/github-webhook/}"
MODE="${1:-webhook}"

usage() {
  cat <<'EOF'
Trigger a local Jenkins pipeline after a git push.

Usage:
  ./scripts/trigger-pipeline.sh [webhook|api|scan]

Modes:
  webhook   Simulate a GitHub push webhook to Jenkins (default)
  api       Trigger the branch build directly via Jenkins REST API
  scan      Trigger a multibranch scan, then build the branch via API

Environment variables:
  JENKINS_URL          Jenkins base URL (default: http://localhost:8080)
  JENKINS_JOB          Jenkins job name (default: job-demo)
  JENKINS_BRANCH       Branch to build (default: main)
  GITHUB_REPO          GitHub repo slug (default: RustyPrione/jenkins-demo)
  JENKINS_USER         Jenkins username (optional)
  JENKINS_API_TOKEN    Jenkins API token (optional)
  WEBHOOK_SECRET       GitHub webhook secret, if configured in Jenkins (optional)

Examples:
  ./scripts/trigger-pipeline.sh
  ./scripts/trigger-pipeline.sh api
  JENKINS_USER=admin JENKINS_API_TOKEN=xxx ./scripts/trigger-pipeline.sh webhook
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! command -v git >/dev/null 2>&1; then
  echo "git is required."
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required."
  exit 1
fi

cd "$ROOT_DIR"

if [ ! -d .git ]; then
  echo "No git repository found in $ROOT_DIR"
  exit 1
fi

BRANCH="${JENKINS_BRANCH:-$(git rev-parse --abbrev-ref HEAD)}"
COMMIT_SHA="$(git rev-parse HEAD)"
COMMIT_SHORT="$(git rev-parse --short HEAD)"
COMMIT_MSG="$(git log -1 --pretty=%B | tr -d '\r' | head -1)"
COMMIT_TIMESTAMP="$(git log -1 --pretty=format:%cI)"
REPO_NAME="${GITHUB_REPO##*/}"
REPO_URL="https://github.com/${GITHUB_REPO}.git"
REPO_HTML_URL="https://github.com/${GITHUB_REPO}"

jenkins_curl() {
  if [ -n "${JENKINS_USER:-}" ] && [ -n "${JENKINS_API_TOKEN:-}" ]; then
    curl -u "${JENKINS_USER}:${JENKINS_API_TOKEN}" "$@"
  else
    curl "$@"
  fi
}

get_crumb_args() {
  local crumb_json crumb_field crumb
  crumb_json="$(jenkins_curl -sf "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null || true)"
  if [ -z "$crumb_json" ]; then
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    crumb_field="$(python3 -c 'import json,sys; data=json.loads(sys.argv[1]); print(data.get("crumbRequestField", "Jenkins-Crumb"))' "$crumb_json")"
    crumb="$(python3 -c 'import json,sys; data=json.loads(sys.argv[1]); print(data.get("crumb", ""))' "$crumb_json")"
  else
    crumb_field="Jenkins-Crumb"
    crumb="$(printf '%s' "$crumb_json" | sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p')"
  fi

  if [ -n "$crumb" ]; then
    printf '%s\n%s' "$crumb_field" "$crumb"
  fi
}

jenkins_post() {
  local url="$1"
  shift
  local crumb_field crumb

  if read -r crumb_field crumb < <(get_crumb_args); then
    if [ -n "${crumb:-}" ]; then
      jenkins_curl -sf -X POST -H "${crumb_field}: ${crumb}" "$url" "$@"
      return
    fi
  fi

  jenkins_curl -sf -X POST "$url" "$@"
}

build_github_payload() {
  export PAYLOAD_BRANCH="$BRANCH"
  export PAYLOAD_REPO_NAME="$REPO_NAME"
  export PAYLOAD_GITHUB_REPO="$GITHUB_REPO"
  export PAYLOAD_REPO_URL="$REPO_URL"
  export PAYLOAD_REPO_HTML_URL="$REPO_HTML_URL"
  export PAYLOAD_COMMIT_SHA="$COMMIT_SHA"
  export PAYLOAD_COMMIT_MSG="$COMMIT_MSG"
  export PAYLOAD_COMMIT_TIMESTAMP="$COMMIT_TIMESTAMP"

  python3 - <<'PY'
import json
import os

payload = {
    "ref": f"refs/heads/{os.environ['PAYLOAD_BRANCH']}",
    "repository": {
        "id": 1,
        "name": os.environ["PAYLOAD_REPO_NAME"],
        "full_name": os.environ["PAYLOAD_GITHUB_REPO"],
        "private": False,
        "html_url": os.environ["PAYLOAD_REPO_HTML_URL"],
        "clone_url": os.environ["PAYLOAD_REPO_URL"],
        "git_url": f"git://github.com/{os.environ['PAYLOAD_GITHUB_REPO']}.git",
        "ssh_url": f"git@github.com:{os.environ['PAYLOAD_GITHUB_REPO']}.git",
        "default_branch": "main",
    },
    "pusher": {
        "name": "local-dev",
        "email": "local-dev@example.com",
    },
    "head_commit": {
        "id": os.environ["PAYLOAD_COMMIT_SHA"],
        "message": os.environ["PAYLOAD_COMMIT_MSG"],
        "timestamp": os.environ["PAYLOAD_COMMIT_TIMESTAMP"],
        "url": f"{os.environ['PAYLOAD_REPO_HTML_URL']}/commit/{os.environ['PAYLOAD_COMMIT_SHA']}",
    },
    "commits": [
        {
            "id": os.environ["PAYLOAD_COMMIT_SHA"],
            "message": os.environ["PAYLOAD_COMMIT_MSG"],
            "timestamp": os.environ["PAYLOAD_COMMIT_TIMESTAMP"],
            "url": f"{os.environ['PAYLOAD_REPO_HTML_URL']}/commit/{os.environ['PAYLOAD_COMMIT_SHA']}",
        }
    ],
}
print(json.dumps(payload))
PY
}

trigger_webhook() {
  local payload signature webhook_url="${JENKINS_URL%/}${WEBHOOK_PATH}"
  payload="$(build_github_payload)"

  echo "Sending GitHub push webhook to ${webhook_url}"
  echo "Repository: ${GITHUB_REPO}"
  echo "Branch: ${BRANCH}"
  echo "Commit: ${COMMIT_SHORT}"

  local curl_args=(
    -sS
    -X POST
    "${webhook_url}"
    -H "Content-Type: application/json"
    -H "X-GitHub-Event: push"
    -H "X-GitHub-Delivery: local-$(date +%s)"
    -H "User-Agent: GitHub-Hookshot/local-trigger"
    --data-binary "$payload"
    -w "\nHTTP_STATUS:%{http_code}\n"
  )

  if [ -n "${WEBHOOK_SECRET:-}" ]; then
    signature="$(printf '%s' "$payload" | openssl dgst -sha256 -hmac "$WEBHOOK_SECRET" | sed 's/^.* //')"
    curl_args+=(-H "X-Hub-Signature-256: sha256=${signature}")
  fi

  response="$(jenkins_curl "${curl_args[@]}")"
  printf '%s\n' "$response"

  if ! printf '%s' "$response" | grep -Eq 'HTTP_STATUS:20[0-9]'; then
    echo ""
    echo "Webhook trigger did not return HTTP 2xx."
    echo "If Jenkins is local, make sure the GitHub plugin is installed and the job uses GitHub as branch source."
    echo "Fallback: ./scripts/trigger-pipeline.sh api"
    exit 1
  fi

  echo "Webhook accepted by Jenkins."
}

trigger_api_build() {
  local build_url="${JENKINS_URL%/}/job/${JENKINS_JOB}/job/${JENKINS_BRANCH}/build?delay=0sec"

  echo "Triggering Jenkins build via API"
  echo "Job: ${JENKINS_JOB}/${JENKINS_BRANCH}"
  echo "Commit: ${COMMIT_SHORT}"
  echo "URL: ${build_url}"

  if jenkins_post "$build_url" -o /dev/null -w "HTTP_STATUS:%{http_code}\n"; then
    echo "Build queued successfully."
  else
    echo "Failed to queue build."
    echo "Check JENKINS_JOB, JENKINS_BRANCH, and credentials if Jenkins security is enabled."
    exit 1
  fi
}

trigger_scan() {
  local scan_url="${JENKINS_URL%/}/job/${JENKINS_JOB}/build?delay=0sec"

  echo "Triggering multibranch scan via API"
  echo "Job: ${JENKINS_JOB}"

  if jenkins_post "$scan_url" -o /dev/null -w "HTTP_STATUS:%{http_code}\n"; then
    echo "Multibranch scan queued."
  else
    echo "Failed to queue multibranch scan."
    exit 1
  fi

  sleep 3
  trigger_api_build
}

case "$MODE" in
  webhook)
    trigger_webhook
    ;;
  api)
    trigger_api_build
    ;;
  scan)
    trigger_scan
    ;;
  *)
    echo "Unknown mode: $MODE"
    usage
    exit 1
    ;;
esac
