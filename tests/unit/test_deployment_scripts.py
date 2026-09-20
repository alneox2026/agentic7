"""Regression checks for the template's safe multi-stack deployment defaults."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def test_cloudshell_scripts_derive_an_isolated_stack_identity() -> None:
    build_script = (ROOT / "scripts" / "cloudshell_build_middleware.sh").read_text(
        encoding="utf-8"
    )
    deploy_script = (ROOT / "scripts" / "cloudshell_deploy_middleware.sh").read_text(
        encoding="utf-8"
    )

    assert 'MIDDLEWARE_STACK_NAME="${MIDDLEWARE_STACK_NAME:-$(basename "${ROOT_DIR}")}"' in build_script
    assert '${MIDDLEWARE_IMAGE_PREFIX}-gateway' in build_script
    assert 'TF_STATE_PREFIX="${TF_STATE_PREFIX:-stacks/${MIDDLEWARE_STACK_NAME}/middleware}"' in deploy_script
    assert '"gateway_service_name":' not in deploy_script
    assert '"firestore_customer_wallets_collection": "customer_wallets_${FIRESTORE_NAMESPACE}"' in deploy_script
    assert '"firestore_subscription_cancellation_requests_collection": "subscription_cancellation_requests_${FIRESTORE_NAMESPACE}"' in deploy_script
    assert 'ALLOW_LEGACY_RESOURCE_NAMES:-false' in deploy_script
    assert 'ceoagent-gateway-v3' in deploy_script


def test_cloudshell_deploy_requires_explicit_recovery_and_delete_approval() -> None:
    deploy_script = (ROOT / "scripts" / "cloudshell_deploy_middleware.sh").read_text(
        encoding="utf-8"
    )
    import_script = (ROOT / "scripts" / "import_existing_resources.sh").read_text(
        encoding="utf-8"
    )

    assert 'IMPORT_EXISTING_RESOURCES:-false' in deploy_script
    assert 'ALLOW_TERRAFORM_DELETES:-false' in deploy_script
    assert 'Refusing to apply.' in deploy_script
    assert 'IMPORT_EXISTING_RESOURCES:-false' in import_script
    assert 'Refusing automatic import.' in import_script


def test_test_wallet_helper_never_defaults_to_a_shared_collection() -> None:
    helper = (ROOT / "scripts" / "provision_test_wallet.py").read_text(encoding="utf-8")
    assert 'os.getenv("MIDDLEWARE_STACK_NAME", "")' in helper
    assert 'customer_wallets_v3' not in helper
    assert 'wallet_transactions_v3' not in helper
