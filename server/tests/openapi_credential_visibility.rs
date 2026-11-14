//! Keeps the OpenAPI document aligned with the credential visibility v1
//! routes registered by the SQLite router.
const OPENAPI: &str = include_str!("../openapi.yaml");

fn operations_for_path(path: &str) -> Vec<&'static str> {
    let path_key = format!("  {path}:\n");
    let start = OPENAPI
        .find(&path_key)
        .unwrap_or_else(|| panic!("OpenAPI path {path} is missing"));
    let section = &OPENAPI[start + path_key.len()..];
    let mut operations = Vec::new();
    for line in section.lines() {
        if line.starts_with("  /") || !line.starts_with("  ") {
            break;
        }
        match line.trim() {
            "get:" => operations.push("get"),
            "post:" => operations.push("post"),
            "put:" => operations.push("put"),
            "delete:" => operations.push("delete"),
            "patch:" => operations.push("patch"),
            _ => {}
        }
    }
    operations.sort_unstable();
    operations
}

#[test]
fn credential_visibility_routes_and_schemas_are_documented() {
    for (path, expected) in [
        ("/credential-visibility", vec!["get"]),
        (
            "/credential-visibility/escrow/{vault_id}/{key_epoch}",
            vec!["put"],
        ),
        (
            "/credential-visibility/vaults/{vault_id}/recipients/{device_id}",
            vec!["get"],
        ),
        ("/admin/credential-visibility", vec!["get", "put"]),
        (
            "/admin/accounts/{user_id}/credential-visibility",
            vec!["put"],
        ),
        ("/admin/credential-escrow/key", vec!["delete", "post"]),
        ("/admin/credential-escrow/key/wrap", vec!["put"]),
        (
            "/admin/credential-escrow/accounts/{user_id}/vaults",
            vec!["get"],
        ),
        (
            "/admin/credential-escrow/vaults/{vault_id}/records",
            vec!["get"],
        ),
    ] {
        assert_eq!(operations_for_path(path), expected, "{path}");
    }
    for schema in [
        "CredentialVisibilityMode",
        "CredentialEscrowStatus",
        "CredentialVisibilityPolicy",
        "CredentialEscrowKeyDescriptor",
        "CredentialEscrowAccountWrap",
        "CredentialEscrowRecoveryWrap",
        "CredentialVisibilityStatus",
        "CredentialVisibilityShareRecipient",
        "CredentialEscrowDepositRequest",
        "CredentialEscrowDepositResult",
        "AdminCredentialVisibilityPolicy",
        "AdminCredentialVisibilityPolicyRequest",
        "AdminAccountCredentialVisibilityRequest",
        "AdminAccountCredentialVisibilityResponse",
        "AdminCredentialEscrowKeyCreateRequest",
        "AdminCredentialEscrowKeyWrapRequest",
        "AdminCredentialEscrowKeyResetRequest",
        "AdminCredentialEscrowAccountVaults",
        "AdminCredentialEscrowRecordPage",
    ] {
        assert!(
            OPENAPI.contains(&format!("\n    {schema}:\n")),
            "schema {schema} is missing"
        );
    }
    for wire in [
        "atermius-credential-escrow-key-v1",
        "atermius-credential-escrow-key-creation-v1",
        "atermius-credential-escrow-deposit-v1",
        "atermius-credential-escrow-v1",
        "CREDENTIAL_ESCROW_NOT_AVAILABLE",
        "credential_visibility_default",
    ] {
        assert!(OPENAPI.contains(wire), "{wire} is not documented");
    }
}
