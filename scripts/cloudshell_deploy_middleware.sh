#!/usr/bin/env bash
set -euo pipefail

# Deploy an isolated middleware stack. The default identity comes from the
# cloned repository directory; set MIDDLEWARE_STACK_NAME explicitly only when
# the directory name is unsuitable.

PROJECT_ID="${PROJECT_ID:-ceo-dev123}"
REGION="${REGION:-us-central1}"
REPOSITORY="${REPOSITORY:-ceosystem}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

MIDDLEWARE_STACK_NAME="${MIDDLEWARE_STACK_NAME:-$(basename "${ROOT_DIR}")}"
MIDDLEWARE_IMAGE_PREFIX="${MIDDLEWARE_IMAGE_PREFIX:-${MIDDLEWARE_STACK_NAME}}"
FIRESTORE_NAMESPACE="${FIRESTORE_NAMESPACE:-${MIDDLEWARE_STACK_NAME//-/_}}"

# A copied template must not silently try to create or import the template's
# original v3 resources. New stacks should replace these defaults in
# infra/terraform/variables.tf before their first deployment.
if [ "${ALLOW_LEGACY_RESOURCE_NAMES:-false}" != "true" ]; then
  for LEGACY_NAME in \
    "ceoagent-gateway-v3" \
    "ceoagent-persistence-worker-v3" \
    "ceoagent-billing-api-v3" \
    "ceoagent-gateway-sa-v3" \
    "ceoagent-worker-sa-v3" \
    "ceoagent-billing-api-sa-v3" \
    "ceoagent-eventarc-sa-v3" \
    "ceoagent-reconciler-sa-v3" \
    "agent-turn-events-v3"; do
    if grep -Fq "default     = \"${LEGACY_NAME}\"" "${ROOT_DIR}/infra/terraform/variables.tf"; then
      echo "ERROR: infra/terraform/variables.tf still contains inherited resource name ${LEGACY_NAME}." >&2
      echo "Set unique service, service-account, and Pub/Sub names for this stack before deploying." >&2
      echo "ALLOW_LEGACY_RESOURCE_NAMES=true is only for a reviewed update of the original legacy stack." >&2
      exit 2
    fi
  done
fi

if [[ ! "${MIDDLEWARE_STACK_NAME}" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "ERROR: MIDDLEWARE_STACK_NAME must contain only lowercase letters, digits, and hyphens, and start with a letter." >&2
  exit 2
fi
if [[ ! "${MIDDLEWARE_IMAGE_PREFIX}" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "ERROR: MIDDLEWARE_IMAGE_PREFIX must contain only lowercase letters, digits, and hyphens, and start with a letter." >&2
  exit 2
fi
if [[ ! "${FIRESTORE_NAMESPACE}" =~ ^[a-z][a-z0-9_]*$ ]]; then
  echo "ERROR: FIRESTORE_NAMESPACE must contain only lowercase letters, digits, and underscores, and start with a letter." >&2
  exit 2
fi

# Resolve only this stack's images. Never fall back to another stack's image,
# because a successful deploy with the wrong image is worse than a fast failure.
if [ -n "${TAG:-}" ] && [ "${TAG}" != "latest" ]; then
  GATEWAY_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${MIDDLEWARE_IMAGE_PREFIX}-gateway:${TAG}"
  WORKER_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${MIDDLEWARE_IMAGE_PREFIX}-persistence-worker:${TAG}"
  BILLING_API_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${MIDDLEWARE_IMAGE_PREFIX}-billing-api:${TAG}"
else
  echo "--> Resolving this stack's :latest image digests from Artifact Registry..."
  GATEWAY_NAME="${MIDDLEWARE_IMAGE_PREFIX}-gateway"
  WORKER_NAME="${MIDDLEWARE_IMAGE_PREFIX}-persistence-worker"
  BILLING_API_NAME="${MIDDLEWARE_IMAGE_PREFIX}-billing-api"

  GATEWAY_DIGEST="$(gcloud artifacts docker images describe "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${GATEWAY_NAME}:latest" --format='value(image_summary.digest)' 2>/dev/null || true)"
  WORKER_DIGEST="$(gcloud artifacts docker images describe "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${WORKER_NAME}:latest" --format='value(image_summary.digest)' 2>/dev/null || true)"
  BILLING_API_DIGEST="$(gcloud artifacts docker images describe "${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${BILLING_API_NAME}:latest" --format='value(image_summary.digest)' 2>/dev/null || true)"

  if [ -z "${GATEWAY_DIGEST}" ] || [ -z "${WORKER_DIGEST}" ] || [ -z "${BILLING_API_DIGEST}" ]; then
    echo "ERROR: One or more ${MIDDLEWARE_IMAGE_PREFIX} images are missing. Run cloudshell_build_middleware.sh successfully first, or pass TAG=<git-sha>." >&2
    exit 1
  fi

  GATEWAY_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${GATEWAY_NAME}@${GATEWAY_DIGEST}"
  WORKER_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${WORKER_NAME}@${WORKER_DIGEST}"
  BILLING_API_IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${REPOSITORY}/${BILLING_API_NAME}@${BILLING_API_DIGEST}"
fi

# A unique remote-state namespace prevents a copied template from claiming an
# existing middleware's resources. Existing legacy stacks must pass their old
# TF_STATE_PREFIX explicitly until they are deliberately migrated.
TF_STATE_PREFIX="${TF_STATE_PREFIX:-stacks/${MIDDLEWARE_STACK_NAME}/middleware}"

echo "================================================================="
echo " Deploying Middleware Infrastructure (Terraform)"
echo " Project ID          : ${PROJECT_ID}"
echo " Region              : ${REGION}"
echo " Stack Name          : ${MIDDLEWARE_STACK_NAME}"
echo " Image Prefix        : ${MIDDLEWARE_IMAGE_PREFIX}"
echo " Firestore Namespace : ${FIRESTORE_NAMESPACE}"
echo " State Prefix        : ${TF_STATE_PREFIX}"
echo " Gateway Image       : ${GATEWAY_IMAGE}"
echo " Worker Image        : ${WORKER_IMAGE}"
echo " Billing API Image   : ${BILLING_API_IMAGE}"
echo "================================================================="

cd "${ROOT_DIR}/infra/terraform"
rm -f terraform.auto.tfvars.json middleware.tfplan

cat > backend.hcl <<EOF
bucket = "${PROJECT_ID}-tfstate"
prefix = "${TF_STATE_PREFIX}"
EOF

terraform init -backend-config=backend.hcl -reconfigure

BILLING_CATALOG_PATH="${BILLING_CATALOG_PATH:-/app/config/billing.prod.yaml}"
EXTRA_TFVARS=",\"billing_api_catalog_path\": \"${BILLING_CATALOG_PATH}\""
if [ -n "${STRIPE_WEBHOOK_SIGNING_SECRET_ID:-}" ]; then
  EXTRA_TFVARS="${EXTRA_TFVARS},\"billing_api_stripe_webhook_signing_secret_id\": \"${STRIPE_WEBHOOK_SIGNING_SECRET_ID}\",\"billing_api_stripe_webhook_signing_secret_version\": \"${STRIPE_WEBHOOK_SIGNING_SECRET_VERSION:-1}\""
fi

cat > terraform.auto.tfvars.json <<EOF
{
  "project_id": "${PROJECT_ID}",
  "region": "${REGION}",
  "gateway_image": "${GATEWAY_IMAGE}",
  "worker_image": "${WORKER_IMAGE}",
  "billing_api_image": "${BILLING_API_IMAGE}",
  "allowed_origins": ["https://ceoappdev.flutterflow.app"],
  "billing_api_allowed_origins": ["https://ceoappdev.flutterflow.app"],
  "billing_api_stripe_secret_key_secret_version": "1",
  "billing_api_checkout_success_url": "https://ceoappdev.flutterflow.app/billing-complete?session_id={CHECKOUT_SESSION_ID}",
  "billing_api_checkout_cancel_url": "https://ceoappdev.flutterflow.app/billing-cancelled",
  "billing_enforcement_enabled": true,
  "billing_reconciliation_enabled": true,
  "firestore_threads_collection": "agent_threads_${FIRESTORE_NAMESPACE}",
  "firestore_messages_subcollection": "messages_${FIRESTORE_NAMESPACE}",
  "firestore_idempotency_collection": "processed_events_${FIRESTORE_NAMESPACE}",
  "firestore_billing_ledger_collection": "agent_billing_ledger_${FIRESTORE_NAMESPACE}",
  "firestore_customer_wallets_collection": "customer_wallets_${FIRESTORE_NAMESPACE}",
  "firestore_billing_reservations_collection": "billing_reservations_${FIRESTORE_NAMESPACE}",
  "firestore_wallet_transactions_collection": "wallet_transactions_${FIRESTORE_NAMESPACE}",
  "firestore_customer_billing_periods_collection": "customer_billing_periods_${FIRESTORE_NAMESPACE}",
  "firestore_customer_billing_accounts_collection": "customer_billing_accounts_${FIRESTORE_NAMESPACE}",
  "firestore_stripe_webhook_events_collection": "stripe_webhook_events_${FIRESTORE_NAMESPACE}",
  "firestore_subscription_cancellation_requests_collection": "subscription_cancellation_requests_${FIRESTORE_NAMESPACE}"${EXTRA_TFVARS}
}
EOF

# Importing another stack's resources makes a renamed configuration look like
# a deletion. Recovery imports are therefore explicitly opt-in.
if [ "${IMPORT_EXISTING_RESOURCES:-false}" = "true" ]; then
  bash "${ROOT_DIR}/scripts/import_existing_resources.sh"
fi

PLAN_FILE="middleware.tfplan"
set +e
terraform plan -detailed-exitcode -out="${PLAN_FILE}"
PLAN_EXIT=$?
set -e

if [ "${PLAN_EXIT}" -eq 0 ]; then
  echo "No infrastructure changes to apply."
  terraform output
  exit 0
elif [ "${PLAN_EXIT}" -ne 2 ]; then
  exit "${PLAN_EXIT}"
fi

DESTRUCTIVE_ADDRESSES="$(terraform show -json "${PLAN_FILE}" | python3 -c '
import json
import sys

for resource in json.load(sys.stdin).get("resource_changes", []):
    if "delete" in resource.get("change", {}).get("actions", []):
        print(resource["address"])
')"

if [ -n "${DESTRUCTIVE_ADDRESSES}" ] && [ "${ALLOW_TERRAFORM_DELETES:-false}" != "true" ]; then
  echo "ERROR: Terraform plans to delete or replace the following resources:" >&2
  echo "${DESTRUCTIVE_ADDRESSES}" >&2
  echo "Refusing to apply. Verify TF_STATE_PREFIX and resource names. Set ALLOW_TERRAFORM_DELETES=true only for an intentional, reviewed deletion." >&2
  exit 1
fi

terraform apply -auto-approve "${PLAN_FILE}"
rm -f "${PLAN_FILE}"

echo "================================================================="
echo " Middleware Deployed Successfully!"
echo "================================================================="
terraform output
