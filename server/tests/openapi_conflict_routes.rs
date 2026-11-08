const OPENAPI: &str = include_str!("../openapi.yaml");

fn operations_for_path(path: &str) -> Vec<&'static str> {
    let path_key = format!("  {path}:\n");
    let start = OPENAPI
        .find(&path_key)
        .unwrap_or_else(|| panic!("OpenAPI path {path} is missing"));
    let section = &OPENAPI[start + path_key.len()..];
    let mut operations = Vec::new();

    for line in section.lines() {
        if line.starts_with("  /") {
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
    operations
}

#[test]
fn conflict_creation_and_incremental_feed_match_the_router_paths() {
    let mut conflict_operations = operations_for_path("/vaults/{vault_id}/conflicts");
    conflict_operations.sort_unstable();
    assert_eq!(conflict_operations, ["get", "post"]);

    assert_eq!(
        operations_for_path("/vaults/{vault_id}/conflict-changes"),
        ["get"]
    );
}

#[test]
fn account_recovery_routes_and_schemas_are_documented() {
    let mut configure_operations = operations_for_path("/auth/recovery");
    configure_operations.sort_unstable();
    assert_eq!(configure_operations, ["delete", "put"]);
    assert_eq!(operations_for_path("/auth/recovery/contexts"), ["get"]);
    assert_eq!(operations_for_path("/auth/recovery/key-envelopes"), ["put"]);
    assert_eq!(operations_for_path("/auth/recovery/start"), ["post"]);
    assert_eq!(operations_for_path("/auth/recovery/inspect"), ["post"]);
    assert_eq!(operations_for_path("/auth/recovery/complete"), ["post"]);

    for schema in [
        "MeResponse",
        "RecoveryConfigureRequest",
        "RecoveryContexts",
        "RecoveryStartResponse",
        "RecoveryInspectRequest",
        "RecoveryInspectResponse",
        "RecoveryCompleteRequest",
        "RecoveryAccountKeyEnvelope",
        "RecoveryKeyEnvelope",
    ] {
        assert!(
            OPENAPI.contains(&format!("    {schema}:\n")),
            "recovery schema {schema} is missing"
        );
    }
    assert!(OPENAPI.contains("ATERMIUS_AUTH_RECOVERY_START_USER_LIMIT"));
    assert!(OPENAPI.contains("ATERMIUS_AUTH_RECOVERY_COMPLETE_USER_LIMIT"));
    assert!(OPENAPI.contains(
        "recovery_status:\n          type: string\n          enum: [disabled, current, stale]"
    ));
}

#[test]
fn dedicated_metrics_credential_routes_and_scope_are_documented() {
    let mut credential_operations = operations_for_path("/admin/metrics-credential");
    credential_operations.sort_unstable();
    assert_eq!(credential_operations, ["delete", "get", "post"]);
    assert_eq!(operations_for_path("/admin/metrics"), ["get"]);

    let metrics_description = OPENAPI
        .split_once("  /admin/metrics:\n")
        .unwrap()
        .1
        .split_once("\n  /")
        .unwrap()
        .0;
    assert!(metrics_description.contains("accepted only by this GET endpoint"));

    let credential_description = OPENAPI
        .split_once("  /admin/metrics-credential:\n")
        .unwrap()
        .1
        .split_once("\n  /")
        .unwrap()
        .0;
    assert!(credential_description.contains("returned exactly once"));
    assert!(credential_description.contains("HMAC-SHA-256 verifier"));
    assert!(credential_description.contains("immediately invalidating the prior value"));
    assert!(credential_description.contains("Revocation immediately disables"));
    assert!(
        credential_description
            .contains("INVALID_REQUEST when a non-empty request body is supplied")
    );
}

#[test]
fn terminal_collaboration_routes_and_wire_schemas_are_documented() {
    assert_eq!(
        operations_for_path("/vaults/{vault_id}/terminal-sessions"),
        ["post"]
    );
    assert_eq!(
        operations_for_path("/vaults/{vault_id}/terminal-sessions/{session_id}/ticket"),
        ["post"]
    );
    assert_eq!(
        operations_for_path("/vaults/{vault_id}/terminal-sessions/{session_id}"),
        ["delete"]
    );
    assert_eq!(operations_for_path("/collaboration/v1/connect"), ["get"]);

    for schema in ["TerminalSessionCreate", "TerminalKeybox", "TerminalFrame"] {
        assert!(
            OPENAPI.contains(&format!("    {schema}:\n")),
            "terminal collaboration schema {schema} is missing"
        );
    }
    assert!(OPENAPI.contains("ticket_expires_at"));
    assert!(OPENAPI.contains("sequence: {type: integer, minimum: 1, maximum: 9007199254740991}"));
    assert!(
        OPENAPI.contains("x-websocket-frame-schema: {$ref: '#/components/schemas/TerminalFrame'}")
    );
}

#[test]
fn instance_and_shared_component_schemas_are_not_shadowed() {
    assert_eq!(OPENAPI.matches("\n  schemas:\n").count(), 1);
    assert_eq!(OPENAPI.matches("\n  securitySchemes:\n").count(), 1);

    let instance_path = OPENAPI
        .split_once("  /instance:\n")
        .expect("instance path is documented")
        .1
        .split_once("\n  /")
        .expect("next path ends instance path section")
        .0;
    assert!(instance_path.contains("schema: {$ref: '#/components/schemas/InstanceInfo'}"));

    let components = OPENAPI
        .split_once("components:\n")
        .expect("components are documented")
        .1;
    let parameters = components
        .find("\n  parameters:\n")
        .expect("component parameters are documented");
    let schemas = [
        "AuditEvent",
        "AuditPage",
        "NotificationTicket",
        "RelayTicket",
        "InstanceInfo",
        "InstanceLimits",
        "DeviceCapabilityReport",
        "VaultDeviceDirectory",
        "VaultDevice",
        "InstanceKeyTransition",
        "ApiError",
        "SyncPageTooLargeError",
        "ChangePage",
        "MembershipChainPage",
        "SignedMembershipRecord",
        "ObjectRefs",
        "RevisionHistoryPage",
        "ConflictHistoryPage",
        "ConflictChangesPage",
        "SignedRecordEnvelope",
    ];
    for schema in schemas {
        let declaration = format!("\n    {schema}:\n");
        let position = components
            .find(&declaration)
            .unwrap_or_else(|| panic!("component schema {schema} is missing"));
        assert!(position < parameters, "schema {schema} must be in schemas");
    }
    assert!(components.contains("\n    bearerAuth: {type: http, scheme: bearer}\n"));
}

#[test]
fn admin_restore_stage_discard_route_and_schemas_are_documented() {
    assert_eq!(
        operations_for_path("/admin/restore-stages/{restore_job_id}/discard"),
        ["post"]
    );
    for schema in [
        "AdminRestoreStageDiscardRequest",
        "AdminRestoreStageDiscardResponse",
    ] {
        assert!(
            OPENAPI.contains(&format!("    {schema}:\n")),
            "restore-stage discard schema {schema} is missing"
        );
    }
    assert!(OPENAPI.contains("restore_stage_status:"));
    assert!(
        OPENAPI.contains(
            "enum: [ready, failed, interrupted, discarding, discarded, unverified, null]"
        )
    );
    assert!(OPENAPI.contains("admin.restore_stage_discarded"));
}
