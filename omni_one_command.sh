#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Omni One-Command Bootstrap
# - Unzips omni_vault.zip (if needed)
# - Starts lock server (FastAPI) and verifies lock semantics
# - Optionally provisions S3 Object Lock vault with Terraform
# - Uploads artifacts to S3
# Everything controlled by flags/env vars. See --help.
# =========================================================

usage() {
  cat <<'EOF'
Usage:
  ./omni_one_command.sh [--mode local|cloud|both]
                        [--bucket <name>] [--region <aws-region>]
                        [--owner-arn <arn>] [--mfa-serial <arn>] [--mfa-code <code>]
                        [--auto-approve]

Env vars (fallbacks if flags not provided):
  OWNER_TOKEN              Strong random token for vault control (auto-generated if empty)
  OMNI_MODE                local | cloud | both           (default: both)
  OMNI_BUCKET              S3 bucket name                 (required for cloud/both)
  OMNI_REGION              AWS region (e.g., us-east-1)   (default: us-east-1)
  OMNI_OWNER_ARN           IAM ARN for owner              (required for cloud/both)
  OMNI_MFA_SERIAL          MFA device ARN                 (optional; for privileged deletes)
  OMNI_MFA_CODE            6-digit code for MFA session   (optional)
  OMNI_AUTO_APPROVE        if "1", pass -auto-approve to terraform apply

Examples:
  ./omni_one_command.sh --mode local
  ./omni_one_command.sh --mode cloud --bucket my-omni-vault --owner-arn arn:aws:iam::123:user/me
  OWNER_TOKEN=$(openssl rand -hex 32) \
  ./omni_one_command.sh --mode both --bucket my-omni --owner-arn arn:aws:iam::123:user/me --auto-approve
EOF
}

# Defaults
OMNI_MODE="${OMNI_MODE:-both}"
OMNI_BUCKET="${OMNI_BUCKET:-}"
OMNI_REGION="${OMNI_REGION:-us-east-1}"
OMNI_OWNER_ARN="${OMNI_OWNER_ARN:-}"
OMNI_MFA_SERIAL="${OMNI_MFA_SERIAL:-}"
OMNI_MFA_CODE="${OMNI_MFA_CODE:-}"
AUTO_APPROVE_FLAG=""

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) OMNI_MODE="$2"; shift 2;;
    --bucket) OMNI_BUCKET="$2"; shift 2;;
    --region) OMNI_REGION="$2"; shift 2;;
    --owner-arn) OMNI_OWNER_ARN="$2"; shift 2;;
    --mfa-serial) OMNI_MFA_SERIAL="$2"; shift 2;;
    --mfa-code) OMNI_MFA_CODE="$2"; shift 2;;
    --auto-approve) AUTO_APPROVE_FLAG="-auto-approve"; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

# Ensure we have OWNER_TOKEN
if [[ -z "${OWNER_TOKEN:-}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    export OWNER_TOKEN="$(openssl rand -hex 32)"
  else
    export OWNER_TOKEN="$(date +%s%N | sha256sum | cut -c1-64 || echo randomfallback)"
  fi
fi
echo "[INFO] OWNER_TOKEN set (hidden)"

# 1) Unzip and start local vault if mode includes local
start_local() {
  if [[ ! -d "omni_vault" ]]; then
    if [[ -f "omni_vault.zip" ]]; then
      echo "[INFO] Unzipping omni_vault.zip..."
      unzip -q omni_vault.zip
    else
      echo "[ERROR] omni_vault.zip not found in $(pwd)."
      exit 1
    }
  fi
  cd omni_vault
  export OMNI_VAULT_OWNER_TOKEN="$OWNER_TOKEN"

  echo "[INFO] Starting local lock server..."
  chmod +x scripts/run_local.sh
  # Run in background
  ( ./scripts/run_local.sh ) > server.log 2>&1 &
  SERVER_PID=$!
  echo "[INFO] Uvicorn started (PID $SERVER_PID). Waiting for health..."

  for i in {1..30}; do
    if curl -s http://localhost:8080/health | grep -q '"status": "ok"'; then
      echo "[INFO] Health OK"
      break
    fi
    sleep 1
  done

  echo "[INFO] Fetching spec to verify..."
  curl -sS http://localhost:8080/spec --output omni_api.yaml

  echo "[INFO] Verifying lock enforcement (upload should fail with 423)..."
  set +e
  RESP=$(curl -s -w "%{http_code}" -o /dev/null -F "file=@data/omni_kg.ttl" \
         -H "Authorization: Bearer $OWNER_TOKEN" \
         http://localhost:8080/upload)
  set -e
  if [[ "$RESP" != "423" ]]; then
    echo "[WARN] Expected 423 while locked, got $RESP"
  else
    echo "[INFO] Upload correctly blocked (423)"
  fi

  echo "[INFO] Unlocking, uploading, and re-locking..."
  curl -sS -H "Authorization: Bearer $OWNER_TOKEN" -H 'Content-Type: application/json' \
       -d '{"locked": false}' http://localhost:8080/lock > /dev/null

  curl -sS -F "file=@data/omni_kg.ttl" -H "Authorization: Bearer $OWNER_TOKEN" \
       http://localhost:8080/upload > /dev/null

  curl -sS http://localhost:8080/files
  curl -sS -H "Authorization: Bearer $OWNER_TOKEN" -H 'Content-Type: application/json' \
       -d '{"locked": true}' http://localhost:8080/lock > /dev/null
  echo
  echo "[INFO] Local vault re-locked."
  cd - >/dev/null
}

# 2) Provision S3 Object Lock + upload if mode includes cloud
provision_cloud() {
  if ! command -v aws >/dev/null 2>&1; then
    echo "[ERROR] aws CLI not found. Install and configure before --mode cloud/both."
    exit 1
  fi
  if ! command -v terraform >/dev/null 2>&1; then
    echo "[ERROR] terraform not found. Install Terraform before --mode cloud/both."
    exit 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "[ERROR] jq not found. Install jq before --mode cloud/both."
    exit 1
  fi

  if [[ -z "$OMNI_BUCKET" || -z "$OMNI_OWNER_ARN" ]]; then
    echo "[ERROR] --bucket and --owner-arn are required for cloud mode."
    exit 1
  fi

  pushd omni_vault/infra/terraform >/dev/null
  echo "[INFO] Terraform init/apply for bucket: $OMNI_BUCKET (region: $OMNI_REGION)"
  terraform init -input=false
  terraform apply $AUTO_APPROVE_FLAG \
    -var="region=$OMNI_REGION" \
    -var="bucket_name=$OMNI_BUCKET" \
    -var="owner_arn=$OMNI_OWNER_ARN"
  popd >/dev/null

  echo "[INFO] Uploading artifacts to s3://$OMNI_BUCKET"
  aws s3 cp omni_vault/api/omni_api.yaml s3://$OMNI_BUCKET/api/omni_api.yaml
  aws s3 cp omni_vault/data/ s3://$OMNI_BUCKET/data/ --recursive

  echo "[INFO] Checking Object Lock attributes for api/omni_api.yaml"
  aws s3api get-object-attributes \
    --bucket "$OMNI_BUCKET" \
    --key api/omni_api.yaml \
    --object-attributes ObjectLockLegalHold,ObjectLockMode,ObjectLockRetainUntilDate || true

  echo "[INFO] Attempting delete without MFA (should be AccessDenied)"
  if aws s3 rm s3://$OMNI_BUCKET/api/omni_api.yaml 2>&1 | grep -qi 'AccessDenied'; then
    echo "[INFO] Delete correctly denied."
  else
    echo "[WARN] Delete did not clearly fail; verify bucket policy and credentials."
  fi

  if [[ -n "$OMNI_MFA_SERIAL" && -n "$OMNI_MFA_CODE" ]]; then
    echo "[INFO] Requesting MFA session..."
    aws sts get-session-token \
      --serial-number "$OMNI_MFA_SERIAL" \
      --token-code "$OMNI_MFA_CODE" > /tmp/omni_mfa.json

    export AWS_ACCESS_KEY_ID=$(jq -r .Credentials.AccessKeyId /tmp/omni_mfa.json)
    export AWS_SECRET_ACCESS_KEY=$(jq -r .Credentials.SecretAccessKey /tmp/omni_mfa.json)
    export AWS_SESSION_TOKEN=$(jq -r .Credentials.SessionToken /tmp/omni_mfa.json)
    echo "[INFO] MFA session acquired. You may now perform owner-only actions with MFA."
  fi
}

# Dispatcher
case "$OMNI_MODE" in
  local) start_local ;;
  cloud) provision_cloud ;;
  both)  start_local; provision_cloud ;;
  *) echo "[ERROR] Invalid mode: $OMNI_MODE"; usage; exit 1 ;;
esac

echo "[DONE] Omni bootstrap complete."
echo " - Local server (if mode includes local): http://localhost:8080"
echo " - Cloud bucket (if mode includes cloud): s3://$OMNI_BUCKET"
