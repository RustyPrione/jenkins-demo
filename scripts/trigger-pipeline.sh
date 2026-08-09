#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -f "$ROOT_DIR/.jenkins-env" ]; then
  # shellcheck disable=SC1091
  set -a
  source "$ROOT_DIR/.jenkins-env"
  set +a
fi

JENKINS_URL="${JENKINS_URL:-http://localhost:8080}"
JENKINS_JOB="${JENKINS_JOB:-job-demo}"
JENKINS_BRANCH="${JENKINS_BRANCH:-main}"
GITHUB_REPO="${GITHUB_REPO:-RustyPrione/jenkins-demo}"
JENKINS_USER="${JENKINS_USER:-admin}"
WEBHOOK_PATH="${WEBHOOK_PATH:-/github-webhook/}"
MODE="${1:-webhook}"

usage() {
  cat <<'EOF'
Trigger a local Jenkins pipeline after a git push.

Usage:
  ./scripts/trigger-pipeline.sh [webhook|api|scan]

Modes:
  webhook   Simulate a GitHub push webhook to Jenkins (default, no login required)
  api       Trigger the branch build directly via Jenkins REST API
  scan      Trigger a multibranch scan, then build the branch via API

Environment variables:
  JENKINS_URL          Jenkins base URL (default: http://localhost:8080)
  JENKINS_JOB          Jenkins job name (default: job-demo)
  JENKINS_BRANCH       Branch to build (default: main)
  GITHUB_REPO          GitHub repo slug (default: RustyPrione/jenkins-demo)
  JENKINS_USER         Jenkins username (required for api/scan when security is on)
  JENKINS_API_TOKEN    Jenkins API token (required for api/scan when security is on)
  WEBHOOK_SECRET       GitHub webhook secret, if configured in Jenkins (optional)

Credentials file:
  Copy jenkins.env.example to .jenkins-env and fill in your Jenkins user/token.

Examples:
  ./scripts/trigger-pipeline.sh webhook
  ./scripts/trigger-pipeline.sh api
  JENKINS_USER=admin JENKINS_API_TOKEN=xxx ./scripts/trigger-pipeline.sh scan
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

print_auth_help() {
  cat <<EOF
Jenkins API access requires authentication.

Create an API token:
  Jenkins UI → your user → Configure → API Token → Add new Token

Then either:

  export JENKINS_USER=admin
  export JENKINS_API_TOKEN=<token>
  ./scripts/trigger-pipeline.sh ${MODE}

Or create .jenkins-env from the example file:

  cp jenkins.env.example .jenkins-env
  # edit .jenkins-env, then rerun this command

If webhook mode is enough for you, use:
  ./scripts/trigger-pipeline.sh webhook
EOF
}

require_jenkins_auth() {
  if [ -n "${JENKINS_USER:-}" ] && [ -n "${JENKINS_API_TOKEN:-}" ]; then
    return 0
  fi

  echo "Missing Jenkins credentials for '${MODE}' mode."
  echo ""
  print_auth_help
  exit 1
}

get_crumb_header() {
  local crumb_json crumb_field crumb
  crumb_json="$(jenkins_curl -s "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null || true)"
  if [ -z "$crumb_json" ]; then
    return 0
  fi
  if ! printf '%s' "$crumb_json" | grep -q '^{'; then
    return 0
  fi

  if command -v python3 >/dev/null 2>&1; then
    crumb_field="$(python3 -c 'import json,sys; data=json.loads(sys.argv[1]); print(data.get("crumbRequestField", "Jenkins-Crumb"))' "$crumb_json" 2>/dev/null || true)"
    crumb="$(python3 -c 'import json,sys; data=json.loads(sys.argv[1]); print(data.get("crumb", ""))' "$crumb_json" 2>/dev/null || true)"
  else
    crumb_field="Jenkins-Crumb"
    crumb="$(printf '%s' "$crumb_json" | sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p')"
  fi

  if [ -n "$crumb" ]; then
    printf '%s: %s' "$crumb_field" "$crumb"
  fi
}

jenkins_post() {
  local url="$1"
  shift
  local http_code crumb_header curl_args=(-sS -X POST)

  if crumb_header="$(get_crumb_header)"; then
    if [ -n "${crumb_header:-}" ]; then
      curl_args+=(-H "$crumb_header")
    fi
  fi

  http_code="$(jenkins_curl "${curl_args[@]}" -o /tmp/jenkins-trigger-body.txt -w "%{http_code}" "$url" "$@")"

  printf 'HTTP_STATUS:%s\n' "$http_code"

  if { [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; } || [ "$http_code" = "302" ]; then
    return 0
  fi

  if [ "$http_code" = "401" ]; then
    echo ""
    echo "Jenkins returned 401 Unauthorized."
    echo "Check JENKINS_USER in .jenkins-env matches the Jenkins account that owns the API token."
    echo "Regenerate the token in Jenkins: User → Configure → API Token"
  fi

  if [ "$http_code" = "403" ]; then
    echo ""
    echo "Jenkins returned 403 Forbidden."
    if [ -z "${JENKINS_USER:-}" ] || [ -z "${JENKINS_API_TOKEN:-}" ]; then
      print_auth_help
    else
      echo "Credentials were provided but Jenkins still rejected the request."
      echo "Check that the user can build job '${JENKINS_JOB}'."
    fi
  fi

  if [ -s /tmp/jenkins-trigger-body.txt ]; then
    echo ""
    echo "Response body:"
    cat /tmp/jenkins-trigger-body.txt
    echo ""
  fi

  return 1
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
  require_jenkins_auth

  local build_url="${JENKINS_URL%/}/job/${JENKINS_JOB}/job/${JENKINS_BRANCH}/build?delay=0sec"

  echo "Triggering Jenkins build via API"
  echo "Job: ${JENKINS_JOB}/${JENKINS_BRANCH}"
  echo "Commit: ${COMMIT_SHORT}"
  echo "URL: ${build_url}"

  if jenkins_post "$build_url"; then
    echo "Build queued successfully."
  else
    echo "Failed to queue build."
    exit 1
  fi
}

trigger_scan() {
  require_jenkins_auth

  local scan_url="${JENKINS_URL%/}/job/${JENKINS_JOB}/build?delay=0sec"

  echo "Triggering multibranch scan via API"
  echo "Job: ${JENKINS_JOB}"

  if jenkins_post "$scan_url"; then
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
