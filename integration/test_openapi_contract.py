"""Structural checks for the published OpenAPI document.

Run with ``pytest integration/test_openapi_contract.py`` or let the normal
``pytest integration/`` collection discover it.
"""

from __future__ import annotations

import re
from pathlib import Path
from urllib.parse import urljoin, urlparse

import yaml


ROOT = Path(__file__).resolve().parents[1]
OPENAPI = yaml.safe_load((ROOT / "server" / "openapi.yaml").read_text(encoding="utf-8"))
API_CONTRACT = (ROOT / "protocol" / "API-CONTRACT.md").read_text(encoding="utf-8")
HTTP_METHODS = {"get", "put", "post", "delete", "patch", "options", "head", "trace"}
PATH_PARAMETER = re.compile(r"\{([^{}]+)\}")


BODY_CONTRACTS: dict[tuple[str, str], tuple[str, set[str]]] = {
    ("/auth/prelogin", "post"): ("application/json", {"username"}),
    ("/auth/register", "post"): (
        "application/json",
        {"account_id", "username", "kdf", "login_verifier", "account_key_envelope", "device", "initial_vault"},
    ),
    ("/auth/login", "post"): ("application/json", {"username", "login_verifier", "device_id"}),
    ("/auth/login/mfa", "post"): ("application/json", {"challenge_id"}),
    ("/auth/mfa/totp/setup", "post"): ("application/json", {"current_login_verifier"}),
    ("/auth/mfa/totp/confirm", "post"): ("application/json", {"current_login_verifier", "totp_code"}),
    ("/auth/mfa/recovery-codes", "post"): ("application/json", {"current_login_verifier", "totp_code"}),
    ("/auth/mfa/totp", "delete"): ("application/json", {"current_login_verifier", "totp_code"}),
    ("/auth/password-change", "post"): (
        "application/json",
        {"operation_id", "current_login_verifier", "new_kdf", "new_login_verifier", "account_key_envelope"},
    ),
    ("/auth/refresh", "post"): ("application/json", {"refresh_token"}),
    ("/account/delete", "post"): ("application/json", {"login_verifier"}),
    ("/account/delete/cancel", "post"): ("application/json", {"username", "login_verifier"}),
    ("/devices", "post"): ("application/json", {"device", "approver_device_id", "certificate_signature"}),
    ("/admin/accounts/{user_id}/status", "put"): ("application/json", {"status"}),
    ("/admin/account-invitations", "post"): ("application/json", {"username"}),
    ("/admin/vaults/{vault_id}/quota", "put"): ("application/json", {"quota_bytes"}),
    ("/admin/relay-policy", "put"): (
        "application/json",
        {"expected_revision", "enabled", "allow_cidrs", "allow_ports"},
    ),
    ("/admin/relay-groups", "post"): ("application/json", {"name"}),
    ("/admin/relay-groups/{group_id}", "put"): (
        "application/json",
        {"expected_revision", "name"},
    ),
    ("/admin/relay-groups/{group_id}", "delete"): (
        "application/json",
        {"expected_revision"},
    ),
    ("/admin/relay-groups/{group_id}/members", "put"): (
        "application/json",
        {"expected_revision", "user_ids"},
    ),
    ("/admin/relay-groups/{group_id}/relay-policy", "put"): (
        "application/json",
        {
            "expected_revision",
            "expected_instance_policy_revision",
            "enabled",
            "allow_cidrs",
            "allow_ports",
        },
    ),
    ("/admin/relay-groups/{group_id}/relay-policy", "delete"): (
        "application/json",
        {"expected_revision"},
    ),
    ("/vaults", "post"): ("application/json", {"vault_id", "name_envelope", "key_envelope", "membership"}),
    ("/vaults/{vault_id}/invitations", "post"): (
        "application/json",
        {"role", "recipient_device_id", "recipient_encryption_public_key", "key_envelope", "membership"},
    ),
    ("/invitations/accept", "post"): ("application/json", {"token"}),
    ("/vaults/{vault_id}/keys/rotate", "post"): ("application/json", {"new_epoch", "membership", "key_envelopes"}),
    ("/vaults/{vault_id}/ownership/transfer", "post"): (
        "application/json",
        {"new_owner_user_id", "new_epoch", "membership", "key_envelopes"},
    ),
    ("/vaults/{vault_id}", "delete"): ("application/json", {"login_verifier"}),
    ("/vaults/{vault_id}/deletion/cancel", "post"): ("application/json", {"login_verifier"}),
    ("/vaults/{vault_id}/sync/push", "post"): (
        "application/json",
        {"protocol_version", "server_generation", "vault_id", "device_id", "batch_id", "operations"},
    ),
    ("/vaults/{vault_id}/records/{record_id}/automatic-purge", "put"): (
        "application/json",
        {"expected_deleted_revision_id", "expected_deleted_seq", "expected_policy_revision", "enabled"},
    ),
    ("/vaults/{vault_id}/conflicts", "post"): ("application/json", {"envelope"}),
    ("/vaults/{vault_id}/conflicts/{conflict_id}/resolve", "post"): (
        "application/json",
        {"resolved_revision_id"},
    ),
    ("/vaults/{vault_id}/uploads/init", "post"): ("application/json", {"object_id", "size", "sha256"}),
    ("/devices/capabilities", "put"): (
        "application/json",
        {
            "account_id",
            "device_id",
            "revision",
            "max_record_schema",
            "host_attachment_manifest_versions",
            "max_attachment_bytes",
            "signature",
        },
    ),
    ("/uploads/{upload_id}/chunks/{index}", "put"): ("application/octet-stream", set()),
    ("/relay/tickets", "post"): ("application/json", {"device_id", "target_host", "target_port"}),
    ("/notifications/push-endpoints/{device_id}", "put"): ("application/json", {"provider", "token"}),
}


def resolve_parameter(parameter: dict) -> dict:
    """Resolve local OpenAPI parameter references before inspecting location/name."""
    seen: set[str] = set()
    while "$ref" in parameter:
        ref = parameter["$ref"]
        assert ref not in seen, f"cyclic parameter reference: {ref}"
        seen.add(ref)
        prefix = "#/components/parameters/"
        assert ref.startswith(prefix), f"unsupported parameter reference: {ref}"
        parameter = OPENAPI["components"]["parameters"][ref[len(prefix) :]]
    return parameter


def resolve_schema(schema: dict) -> dict:
    """Follow local schema refs so assertions inspect the actual object shape."""
    seen: set[str] = set()
    while "$ref" in schema:
        ref = schema["$ref"]
        assert ref not in seen, f"cyclic schema reference: {ref}"
        seen.add(ref)
        prefix = "#/components/schemas/"
        assert ref.startswith(prefix), f"unsupported schema reference: {ref}"
        schema = OPENAPI["components"]["schemas"][ref[len(prefix) :]]
    return schema


def test_each_path_template_parameter_is_declared_on_every_operation() -> None:
    paths = OPENAPI["paths"]
    for path, path_item in paths.items():
        expected = set(PATH_PARAMETER.findall(path))
        for method, operation in path_item.items():
            if method.lower() not in HTTP_METHODS:
                continue
            parameters = [
                resolve_parameter(parameter)
                for parameter in [
                    *path_item.get("parameters", []),
                    *operation.get("parameters", []),
                ]
            ]
            path_parameters = [parameter for parameter in parameters if parameter.get("in") == "path"]
            declared = {parameter.get("name") for parameter in path_parameters}
            assert declared == expected, (
                f"{method.upper()} {path}: expected path parameters {sorted(expected)}, "
                f"declared {sorted(str(name) for name in declared)}"
            )
            for parameter in path_parameters:
                assert parameter.get("required") is True, f"{method.upper()} {path}: path parameter must be required"
                schema = parameter.get("schema")
                assert isinstance(schema, dict) and schema, (
                    f"{method.upper()} {path}: path parameter {parameter.get('name')} has no schema"
                )


def test_admin_prometheus_metrics_is_documented_as_authenticated_text_exposition() -> None:
    operation = OPENAPI["paths"]["/admin/metrics"]["get"]
    assert "security" not in operation  # inherits the bearer requirement at document root
    response = operation["responses"]["200"]
    media = response["content"]["text/plain; version=0.0.4"]
    assert media["schema"] == {"type": "string"}
    assert "401" in operation["responses"]
    assert "403" in operation["responses"]
    description = operation["description"].lower()
    assert "low-cardinality" in description
    assert "caller-controlled labels" in description
    assert "object-delete queue states" in description
    assert "retry_wait" in description
    assert "storage keys" in description
    assert "atermius_mobile_push_send_results_total" in description
    assert "process-local" in description
    assert "resets on process restart" in description
    assert "accepted means the adapter returned success" in description
    assert "does not prove device receipt or sync" in description
    assert "raw provider errors are never exported" in description


def test_admin_push_health_contract_is_fixed_aggregate_only_and_database_timed() -> None:
    path_item = OPENAPI["paths"]["/admin/push-health"]
    assert set(path_item) == {"get"}
    operation = path_item["get"]
    assert "security" not in operation  # inherits the bearer requirement at document root
    assert {"401", "403", "200"} <= operation["responses"].keys()
    description = operation["description"].lower()
    for phrase in (
        "exactly the fixed provider rows",
        "apns and fcm_v1",
        "loaded that provider adapter",
        "including registrations whose account or device is inactive",
        "regardless of account/device status and local adapter configuration",
        "expired lease is therefore due",
        "same database clock sample",
        "seven utc calendar dates",
        "persisted by all nodes",
        "device receipt or synchronization",
        "provider errors",
    ):
        assert phrase in description

    response = resolve_schema(
        operation["responses"]["200"]["content"]["application/json"]["schema"]
    )
    assert response["additionalProperties"] is False
    assert set(response["required"]) == {"generated_at", "delivery_window", "providers"}
    delivery_window = resolve_schema(response["properties"]["delivery_window"])
    assert set(delivery_window["required"]) == {"days", "start_date_utc", "end_date_utc"}
    assert delivery_window["properties"]["days"]["enum"] == [7]
    providers = response["properties"]["providers"]
    assert providers["minItems"] == providers["maxItems"] == 2
    provider = resolve_schema(providers["items"])
    assert provider["additionalProperties"] is False
    assert set(provider["required"]) == {
        "provider",
        "configured",
        "registered_endpoints",
        "due",
        "retry_waiting",
        "leased",
        "dead_lettered",
        "delivery_results",
    }
    assert provider["properties"]["provider"]["enum"] == ["apns", "fcm_v1"]
    for key in ("registered_endpoints", "due", "retry_waiting", "leased", "dead_lettered"):
        schema = provider["properties"][key]
        assert schema["type"] == "integer"
        assert schema["minimum"] == 0
    assert provider["properties"]["configured"]["type"] == "boolean"
    delivery_results = resolve_schema(provider["properties"]["delivery_results"])
    assert set(delivery_results["required"]) == {"accepted", "invalid_token", "retryable_failure"}
    assert delivery_results["additionalProperties"] is False
    for schema in delivery_results["properties"].values():
        assert schema["type"] == "integer" and schema["minimum"] == 0
    assert not {
        "endpoint_id",
        "device_id",
        "token",
        "payload",
        "provider_error",
        "response_body",
        "project_id",
    } & provider["properties"].keys()


def test_vault_members_contract_exposes_only_safe_invitation_status() -> None:
    operation = OPENAPI["paths"]["/vaults/{vault_id}/members"]["get"]
    response_schema = resolve_schema(
        operation["responses"]["200"]["content"]["application/json"]["schema"]
    )
    member_schema = response_schema["properties"]["members"]["items"]
    assert "invitation" in member_schema["required"]
    invitation_schema = member_schema["properties"]["invitation"]
    assert len(invitation_schema["oneOf"]) == 2
    invitation_object = next(
        branch for branch in invitation_schema["oneOf"] if branch.get("type") == "object"
    )
    assert set(invitation_object["required"]) == {"status", "expires_at"}
    assert invitation_object["properties"]["status"]["enum"] == [
        "pending",
        "expired",
        "stale",
        "reissue_required",
    ]
    assert invitation_object["properties"]["expires_at"]["type"] == ["string", "null"]
    assert set(invitation_object["properties"]) == {"status", "expires_at"}
    description = operation["description"].lower()
    assert "issuance_order" in description
    assert "equal timestamps" in description
    assert "historical rows with null issuance_order" in description
    assert "revoked or missing recipient device" in description
    assert "expiry takes precedence" in description


def test_recovery_start_documents_global_live_challenge_cap() -> None:
    operation = OPENAPI["paths"]["/auth/recovery/start"]["post"]
    description = operation["description"].lower()
    assert "atermius_max_active_recovery_challenges" in description
    assert "null-owner decoy rows" in description
    assert "earliest live expiry" in description
    assert "429" in operation["responses"]


def test_vault_presence_contract_is_lease_only_and_has_no_request_body() -> None:
    path_item = OPENAPI["paths"]["/vaults/{vault_id}/presence"]
    listing = path_item["get"]
    list_schema = resolve_schema(
        listing["responses"]["200"]["content"]["application/json"]["schema"]
    )
    assert set(list_schema["required"]) == {"devices", "ttl_seconds"}
    assert set(list_schema["properties"]) == {"devices", "ttl_seconds"}
    assert list_schema["additionalProperties"] is False
    assert list_schema["properties"]["ttl_seconds"]["const"] == 90
    device_schema = resolve_schema(list_schema["properties"]["devices"]["items"])
    assert set(device_schema["required"]) == {"user_id", "device_id", "last_seen_at"}
    assert set(device_schema["properties"]) == {
        "user_id",
        "device_id",
        "last_seen_at",
    }
    assert device_schema["additionalProperties"] is False
    assert "vault_id" not in list_schema["properties"]

    heartbeat = path_item["post"]
    assert "requestBody" not in heartbeat
    assert {"200", "400", "401", "403", "404", "409", "429"} <= set(
        heartbeat["responses"]
    )
    description = heartbeat["description"].lower()
    for required_phrase in (
        "90 seconds",
        "30 seconds",
        "8 live session leases",
        "100,000 live",
        "5-second window",
        "does not extend the lease",
        "maintenance",
        "audit events",
        "content",
        "caller-supplied principal",
    ):
        assert required_phrase in description
    heartbeat_schema = resolve_schema(
        heartbeat["responses"]["200"]["content"]["application/json"]["schema"]
    )
    assert heartbeat_schema["additionalProperties"] is False


def test_mobile_push_contract_is_device_bound_privacy_safe_and_provider_scoped() -> None:
    register = OPENAPI["paths"]["/notifications/push-endpoints/{device_id}"]["put"]
    request_schema = resolve_schema(
        register["requestBody"]["content"]["application/json"]["schema"]
    )
    assert request_schema["additionalProperties"] is False
    assert set(request_schema["required"]) == {"provider", "token"}
    assert request_schema["properties"]["provider"]["enum"] == ["fcm_v1", "apns"]
    provider_tokens = {
        variant["properties"]["provider"]["const"]: variant["properties"]["token"]
        for variant in request_schema["oneOf"]
    }
    fcm_token = provider_tokens["fcm_v1"]
    assert fcm_token["minLength"] == 16
    assert fcm_token["maxLength"] == 4096
    assert fcm_token["pattern"] == "^[!-~]{16,4096}$"
    apns_token = provider_tokens["apns"]
    assert apns_token["minLength"] == 32
    assert apns_token["maxLength"] == 512
    assert apns_token["pattern"] == "^(?:[0-9A-Fa-f]{2}){16,256}$"
    response_schema = resolve_schema(
        register["responses"]["200"]["content"]["application/json"]["schema"]
    )
    assert "token" not in response_schema["properties"]
    assert "token_hash" not in response_schema["properties"]
    assert "token_envelope" not in response_schema["properties"]
    assert "503" in register["responses"]
    assert {"400", "401", "403", "409", "415", "422", "503"} <= set(register["responses"])
    assert "PUSH_DELIVERY_DISABLED" in register["responses"]["503"]["description"]
    description = register["description"].lower()
    assert "current device id" in description
    assert "never included in logs" in description
    assert "sync_available" in description
    assert "atermius_fcm_service_account_file" in description
    assert "apns" in description
    assert "apns is currently unsupported" not in description
    for required_config in (
        "atermius_apns_private_key_file",
        "atermius_apns_team_id",
        "atermius_apns_key_id",
        "atermius_apns_topic",
        "atermius_apns_use_sandbox=true",
        "fixed sandbox host",
        "fixed production host",
    ):
        assert required_config in description
    assert "at-least-once" in description

    delete = OPENAPI["paths"]["/notifications/push-endpoints/{device_id}/{provider}"]["delete"]
    provider = next(p for p in delete["parameters"] if p["name"] == "provider")
    assert provider["schema"]["enum"] == ["fcm_v1", "apns"]
    assert "idempotent" in delete["description"].lower()


def test_admin_account_invitation_contract_keeps_token_issue_only_and_strict() -> None:
    path = OPENAPI["paths"]["/admin/account-invitations"]
    listing = resolve_schema(
        path["get"]["responses"]["200"]["content"]["application/json"]["schema"]
    )
    assert set(listing["required"]) == {"invitations", "total", "limit", "offset"}
    assert listing["additionalProperties"] is False
    invitation = resolve_schema(listing["properties"]["invitations"]["items"])
    assert set(invitation["required"]) == {
        "invitation_id",
        "username",
        "created_at",
        "expires_at",
        "status",
    }
    assert invitation["additionalProperties"] is False
    assert invitation["properties"]["status"]["enum"] == [
        "pending",
        "expired",
        "consumed",
        "revoked",
    ]
    assert not {"token", "token_hash", "hash"} & invitation["properties"].keys()

    create = path["post"]
    assert "201" in create["responses"]
    request = resolve_schema(
        create["requestBody"]["content"]["application/json"]["schema"]
    )
    assert request["additionalProperties"] is False
    assert set(request["required"]) == {"username"}
    assert request["properties"]["expires_in_seconds"]["default"] == 604800
    assert request["properties"]["expires_in_seconds"]["minimum"] == 60
    assert request["properties"]["expires_in_seconds"]["maximum"] == 2592000
    username = request["properties"]["username"]
    assert username["maxLength"] == 320
    assert username["x-maxUtf8Bytes"] == 320
    assert "normalized UTF-8 encoding is limited to 320 bytes" in username["description"]
    created = resolve_schema(
        create["responses"]["201"]["content"]["application/json"]["schema"]
    )
    issued_invitation = created["properties"]["invitation"]
    assert issued_invitation["additionalProperties"] is False
    assert set(issued_invitation["required"]) == {
        "invitation_id",
        "username",
        "created_at",
        "expires_at",
        "token",
    }
    assert issued_invitation["properties"]["token"]["minLength"] == 43

    revoke = OPENAPI["paths"]["/admin/account-invitations/{invitation_id}/revoke"]["post"]
    revoked = resolve_schema(
        revoke["responses"]["200"]["content"]["application/json"]["schema"]
    )
    assert set(revoked["required"]) == {"invitation_id", "status", "revoked_at"}
    assert revoked["properties"]["status"]["const"] == "revoked"
    assert "409" in revoke["responses"]
    assert "ACCOUNT_INVITATION_NOT_PENDING" in revoke["responses"]["409"]["description"]


def test_body_receiving_router_operations_have_structural_request_schemas() -> None:
    paths = OPENAPI["paths"]
    for (path, method), (media_type, required_fields) in BODY_CONTRACTS.items():
        assert path in paths, f"body route missing from OpenAPI: {method.upper()} {path}"
        operation = paths[path].get(method)
        assert isinstance(operation, dict), f"operation missing from OpenAPI: {method.upper()} {path}"
        request_body = operation.get("requestBody")
        assert isinstance(request_body, dict), f"requestBody missing: {method.upper()} {path}"
        assert request_body.get("required") is True, f"requestBody must be required: {method.upper()} {path}"
        content = request_body.get("content")
        assert isinstance(content, dict) and media_type in content, (
            f"{method.upper()} {path}: expected request media type {media_type}"
        )
        schema = content[media_type].get("schema")
        assert isinstance(schema, dict) and schema, f"{method.upper()} {path}: request schema missing"
        schema = resolve_schema(schema)
        if media_type == "application/octet-stream":
            assert schema.get("type") == "string" and schema.get("format") == "binary", (
                f"{method.upper()} {path}: raw upload body must be a binary string schema"
            )
            continue
        assert schema.get("type") == "object", f"{method.upper()} {path}: JSON body must be an object schema"
        properties = schema.get("properties")
        assert isinstance(properties, dict) and required_fields <= properties.keys(), (
            f"{method.upper()} {path}: schema is missing expected properties "
            f"{sorted(required_fields - properties.keys()) if isinstance(properties, dict) else sorted(required_fields)}"
        )
        required = set(schema.get("required", []))
        assert required_fields <= required, (
            f"{method.upper()} {path}: schema does not require fields "
            f"{sorted(required_fields - required)}"
        )


def test_device_capability_reports_and_server_limits_are_separate_contracts() -> None:
    marker = OPENAPI["components"]["parameters"]["ClientCapabilityMarker"]
    assert marker["name"] == "X-Atermius-Capability-Marker"
    assert marker["in"] == "header"
    assert set(marker["schema"]["enum"]) == {"v1", "v2"}
    assert "unsigned" in marker["description"]
    for route in (
        "/vaults/{vault_id}/changes",
        "/vaults/{vault_id}/snapshots",
        "/snapshots/{snapshot_id}",
        "/vaults/{vault_id}/revisions",
        "/vaults/{vault_id}/revisions/{revision_id}",
        "/vaults/{vault_id}/conflicts",
        "/vaults/{vault_id}/conflict-changes",
    ):
        operation = OPENAPI["paths"][route]["get" if route != "/vaults/{vault_id}/snapshots" else "post"]
        refs = {parameter.get("$ref") for parameter in operation.get("parameters", [])}
        assert "#/components/parameters/ClientCapabilityMarker" in refs, route

    report = OPENAPI["components"]["schemas"]["DeviceCapabilityReport"]
    report_fields = {
        "account_id",
        "device_id",
        "revision",
        "max_record_schema",
        "host_attachment_manifest_versions",
        "max_attachment_bytes",
        "signature",
    }
    assert set(report["required"]) == report_fields
    assert set(report["properties"]) == report_fields
    assert report["additionalProperties"] is False
    assert report["properties"]["max_attachment_bytes"]["maximum"] == 1_073_741_824

    vault_device = OPENAPI["components"]["schemas"]["VaultDevice"]
    assert "membership_status" in vault_device["required"]
    assert "redaction_capability_report" in vault_device["required"]
    report_ref = vault_device["properties"]["redaction_capability_report"]["anyOf"][0]["$ref"]
    assert report_ref == "#/components/schemas/VaultDeviceRedactionCapabilityReport"
    redaction_report = OPENAPI["components"]["schemas"]["VaultDeviceRedactionCapabilityReport"]
    assert set(redaction_report["required"]) == {
        "format",
        "account_id",
        "device_id",
        "revision",
        "sync_redaction_version",
        "signature",
        "invalidated_at",
    }
    assert redaction_report["properties"]["invalidated_at"]["type"] == ["string", "null"]
    assert set(vault_device["properties"]["membership_status"]["enum"]) == {
        "active",
        "invited",
        "revoked",
        "archived",
    }
    assert OPENAPI["paths"]["/vaults/{vault_id}/devices"]["get"]["responses"]["200"]["content"]["application/json"]["schema"]["$ref"] == "#/components/schemas/VaultDeviceDirectory"

    instance = OPENAPI["components"]["schemas"]["InstanceInfo"]
    assert "limits" in instance["required"]
    limits = resolve_schema(instance["properties"]["limits"])
    assert set(limits["required"]) == {
        "max_object_bytes",
        "max_upload_chunk_bytes",
        "max_record_object_refs",
    }
    assert "device_capability_reports" in instance["properties"]["capabilities"]["items"]["enum"]
    assert "current verified capability report" in OPENAPI["paths"]["/vaults/{vault_id}/sync/push"]["post"]["description"]
    assert "membership_status" in OPENAPI["paths"]["/vaults/{vault_id}/devices"]["get"]["description"]


def test_snapshot_manifest_pages_require_the_bound_server_generation() -> None:
    operation = OPENAPI["paths"]["/snapshots/{snapshot_id}"]["get"]
    response = operation["responses"]["200"]["content"]["application/json"]
    schema = resolve_schema(response["schema"])
    assert "server_generation" in schema["required"]
    generation = resolve_schema(schema["properties"]["server_generation"])
    assert generation["type"] == "string"
    assert generation["format"] == "uuid"
    assert "server generation" in generation["description"]
    assert "cursor" in generation["description"]


def test_revision_history_restore_until_is_optional_nullable_rfc3339_metadata() -> None:
    page = resolve_schema(OPENAPI["components"]["schemas"]["RevisionHistoryPage"])
    item = page["properties"]["revisions"]["items"]
    normal, redacted = item["oneOf"]
    restore_until = normal["properties"]["restore_until"]

    assert "restore_until" not in normal["required"]
    assert restore_until["type"] == ["string", "null"]
    assert restore_until["format"] == "date-time"
    assert "delete revisions" in restore_until["description"]
    assert redacted["properties"]["restore_until"]["type"] == "null"

    assert "auto_purge_enabled" not in normal["required"]
    assert normal["properties"]["auto_purge_enabled"]["type"] == "boolean"
    assert "auto_purge_revision" not in normal["required"]
    auto_purge_revision = normal["properties"]["auto_purge_revision"]
    assert auto_purge_revision["type"] == "string"
    assert auto_purge_revision["pattern"] == r"^(0|[1-9][0-9]*)$"
    assert "auto_purge_enabled" not in redacted["properties"]
    assert "auto_purge_revision" not in redacted["properties"]
    assert redacted["additionalProperties"] is False

    history_description = OPENAPI["paths"]["/vaults/{vault_id}/revisions"]["get"]["description"]
    assert "fixed restore deadline for delete revisions" in history_description
    assert "null for non-delete revisions" in history_description
    assert "older servers may omit the field" in history_description
    assert "can change independently of the snapshot high watermark" in history_description
    assert "auto_purge_enabled" in history_description
    assert "auto_purge_revision" in history_description
    assert "omitted for non-delete and redacted rows" in history_description

    assert "Later setting changes do not move a deadline already fixed" in API_CONTRACT
    assert "using the restore-retention value recorded in that archive's runtime-policy manifest" in API_CONTRACT
    assert "automatic time-based tombstone purge remains disabled" in API_CONTRACT.lower()


def test_per_tombstone_automatic_purge_consent_is_strict_and_owner_gated() -> None:
    path = "/vaults/{vault_id}/records/{record_id}/automatic-purge"
    operation = OPENAPI["paths"][path]["put"]
    request = resolve_schema(
        operation["requestBody"]["content"]["application/json"]["schema"]
    )
    assert request["additionalProperties"] is False
    assert set(request["required"]) == {
        "expected_deleted_revision_id",
        "expected_deleted_seq",
        "expected_policy_revision",
        "enabled",
    }
    assert set(request["properties"]) == set(request["required"])
    assert request["properties"]["expected_deleted_seq"]["pattern"] == r"^[1-9][0-9]*$"
    assert request["properties"]["expected_policy_revision"]["pattern"] == r"^(0|[1-9][0-9]*)$"
    assert request["properties"]["enabled"]["type"] == "boolean"

    response = resolve_schema(
        operation["responses"]["200"]["content"]["application/json"]["schema"]
    )
    assert response["additionalProperties"] is False
    assert set(response["required"]) == {
        "vault_id",
        "record_id",
        "deleted_revision_id",
        "deleted_seq",
        "enabled",
        "policy_revision",
    }
    assert set(response["properties"]) == set(response["required"])
    assert response["properties"]["enabled"]["type"] == "boolean"
    assert response["properties"]["policy_revision"]["pattern"] == r"^(0|[1-9][0-9]*)$"
    refs = {parameter.get("$ref") for parameter in operation.get("parameters", [])}
    assert "#/components/parameters/ClientRedactionMarker" in refs
    description = operation["description"].lower()
    assert "planned contract" not in description
    assert "not exposed" not in description
    assert "only the active vault owner" in description
    assert "exact current retained tombstone" in description
    assert "compare-and-set value" in description
    assert "writes the vault audit action" in description
    assert "postgresql additionally requires" in description
    assert "no automatic purge worker or scheduler currently runs" in description
    assert "legacy backups without this exact consent state restore opted out" in description
    assert "RECORD_TOMBSTONE_CHANGED" in operation["responses"]["409"]["description"]
    assert "RECORD_AUTO_PURGE_POLICY_REVISION_CONFLICT" in operation["responses"]["409"]["description"]
    assert "CLIENT_REDACTION_CAPABILITY_REQUIRED" in operation["responses"]["426"]["description"]
    assert "not exposed by current server builds" not in API_CONTRACT
    assert "no automatic purge worker or scheduler currently runs" in API_CONTRACT.lower()
    assert "expected_policy_revision" in API_CONTRACT


def test_relay_ticket_contract_supports_bounded_dns_and_pinned_targets() -> None:
    operation = OPENAPI["paths"]["/relay/tickets"]["post"]
    request = resolve_schema(
        operation["requestBody"]["content"]["application/json"]["schema"]
    )
    target_host = request["properties"]["target_host"]
    assert target_host["maxLength"] == 254
    assert "ASCII IDNA A-labels" in target_host["description"]
    assert "maximum 253 normalized bytes" in target_host["description"]
    assert "selected IP is pinned" in target_host["description"]
    assert {"400", "403", "502", "503"} <= set(operation["responses"])
    description = operation["description"].lower()
    for phrase in (
        "a and aaaa",
        "two-second timeout",
        "maximum of 32 addresses",
        "at most 32 dns resolutions run concurrently",
        "selected ip",
        "without echoing the hostname",
    ):
        assert phrase in description
    assert "target_resolution_failed" in API_CONTRACT.lower()
    assert "group-specific network rules remain unimplemented" in API_CONTRACT.lower()


def test_admin_relay_policy_is_strict_versioned_and_deployment_bounded() -> None:
    path_item = OPENAPI["paths"]["/admin/relay-policy"]
    request_schema = resolve_schema(
        path_item["put"]["requestBody"]["content"]["application/json"]["schema"]
    )
    assert request_schema["additionalProperties"] is False
    assert set(request_schema["required"]) == {
        "expected_revision",
        "enabled",
        "allow_cidrs",
        "allow_ports",
    }
    assert set(request_schema["properties"]) == set(request_schema["required"])
    assert request_schema["properties"]["expected_revision"]["minimum"] == 0
    assert "409" in path_item["put"]["responses"]
    assert "RELAY_POLICY_CONFLICT" in path_item["put"]["responses"]["409"]["description"]
    assert "422" in path_item["put"]["responses"]
    assert "RELAY_POLICY_UNAVAILABLE" in path_item["put"]["responses"]["422"]["description"]
    assert "RELAY_POLICY_OUTSIDE_LIMITS" in path_item["put"]["responses"]["422"]["description"]
    assert request_schema["properties"]["allow_cidrs"]["maxItems"] == 256
    assert request_schema["properties"]["allow_cidrs"]["items"]["maxLength"] == 64
    assert request_schema["properties"]["allow_ports"]["maxItems"] == 4096

    for method in ("get", "put"):
        response = path_item[method]["responses"]["200"]["content"]["application/json"]["schema"]
        schema = resolve_schema(response)
        assert schema["additionalProperties"] is False
        assert set(schema["required"]) == {
            "policy",
            "deployment_limits",
            "max_connections_per_user",
            "revision",
            "updated_at",
        }
        assert resolve_schema(schema["properties"]["policy"])["additionalProperties"] is False
        limits = resolve_schema(schema["properties"]["deployment_limits"])
        assert limits["additionalProperties"] is False
        assert set(limits["required"]) == {"relay_available", "allow_cidrs", "allow_ports"}
        assert "deployment" in path_item[method]["description"].lower()


def test_admin_relay_user_policy_is_strict_cas_and_intersection_bounded() -> None:
    path_item = OPENAPI["paths"]["/admin/relay-policy/users/{user_id}"]
    assert path_item["parameters"] == [
        {
            "name": "user_id",
            "in": "path",
            "required": True,
            "description": "Account UUID selected by an authenticated instance administrator; ticket requests cannot select their authorization identity.",
            "schema": {"type": "string", "format": "uuid"},
        }
    ]
    request_schema = resolve_schema(
        path_item["put"]["requestBody"]["content"]["application/json"]["schema"]
    )
    assert request_schema["additionalProperties"] is False
    assert set(request_schema["required"]) == {
        "expected_revision",
        "expected_instance_policy_revision",
        "enabled",
        "allow_cidrs",
        "allow_ports",
    }
    assert set(request_schema["properties"]) == set(request_schema["required"])
    assert request_schema["properties"]["expected_revision"]["minimum"] == 0
    assert request_schema["properties"]["expected_instance_policy_revision"]["minimum"] == 0
    assert request_schema["properties"]["expected_instance_policy_revision"]["format"] == "int64"
    assert request_schema["properties"]["allow_cidrs"]["maxItems"] == 256
    assert request_schema["properties"]["allow_ports"]["maxItems"] == 4096

    for method in ("get", "put", "delete"):
        operation = path_item[method]
        response_schema = resolve_schema(
            operation["responses"]["200"]["content"]["application/json"]["schema"]
        )
        assert response_schema["additionalProperties"] is False
        assert set(response_schema["required"]) == {
            "user_id",
            "inherited",
            "policy",
            "effective_policy",
            "instance_policy_revision",
            "revision",
            "updated_at",
        }
        assert "401" in operation["responses"] and "403" in operation["responses"]
        assert "RELAY_USER_NOT_FOUND" in operation["responses"]["404"]["description"]

    reset_schema = resolve_schema(
        path_item["delete"]["requestBody"]["content"]["application/json"]["schema"]
    )
    assert reset_schema["additionalProperties"] is False
    assert reset_schema["required"] == ["expected_revision"]
    assert set(reset_schema["properties"]) == {"expected_revision"}
    assert "follows later instance policy changes" in path_item["delete"]["description"]
    assert "revision watermark" in path_item["delete"]["description"]
    assert "revokes the target account's unused tickets atomically" in path_item["delete"]["description"]
    assert "409" in path_item["delete"]["responses"]
    assert "RELAY_USER_POLICY_CONFLICT" in path_item["delete"]["responses"]["409"]["description"]

    assert "409" in path_item["put"]["responses"]
    assert "RELAY_USER_POLICY_CONFLICT" in path_item["put"]["responses"]["409"]["description"]
    assert "expected_instance_policy_revision" in path_item["put"]["responses"]["409"]["description"]
    assert "422" in path_item["put"]["responses"]
    assert "RELAY_USER_POLICY_OUTSIDE_LIMITS" in path_item["put"]["responses"]["422"]["description"]
    effective = resolve_schema(
        resolve_schema(path_item["get"]["responses"]["200"]["content"]["application/json"]["schema"])
        ["properties"]["effective_policy"]
    )
    assert set(effective["required"]) == {"enabled", "allow_cidrs", "allow_ports"}


def test_admin_relay_groups_have_independent_cas_and_server_authoritative_acl_contract() -> None:
    paths = OPENAPI["paths"]
    list_path = paths["/admin/relay-groups"]
    create_schema = resolve_schema(
        list_path["post"]["requestBody"]["content"]["application/json"]["schema"]
    )
    assert create_schema["additionalProperties"] is False
    assert create_schema["required"] == ["name"]
    name = create_schema["properties"]["name"]
    assert name["maxLength"] == 80 and name["x-maxUtf8Bytes"] == 320
    assert "NFKC" in name["description"]
    assert "case folding" in name["description"]
    assert "client-owned encrypted Vault" in list_path["post"]["description"]

    listing_schema = resolve_schema(
        list_path["get"]["responses"]["200"]["content"]["application/json"]["schema"]
    )
    summary = resolve_schema(listing_schema["properties"]["groups"]["items"])
    assert set(summary["required"]) == {
        "group_id",
        "name",
        "revision",
        "membership_revision",
        "policy_revision",
        "member_count",
        "policy_inherited",
        "updated_at",
    }

    group_path = paths["/admin/relay-groups/{group_id}"]
    assert group_path["parameters"][0]["schema"]["format"] == "uuid"
    detail = resolve_schema(
        group_path["get"]["responses"]["200"]["content"]["application/json"]["schema"]
    )
    assert set(detail["required"]) == {"group", "members", "policy"}
    members = resolve_schema(detail["properties"]["members"])
    assert set(members["required"]) == {"revision", "items"}
    member = resolve_schema(members["properties"]["items"]["items"])
    assert set(member["properties"]) == {"user_id", "username"}
    for method in ("get", "put", "delete"):
        assert "401" in group_path[method]["responses"]
        assert "403" in group_path[method]["responses"]

    membership_path = paths["/admin/relay-groups/{group_id}/members"]["put"]
    membership_request = resolve_schema(
        membership_path["requestBody"]["content"]["application/json"]["schema"]
    )
    assert membership_request["additionalProperties"] is False
    assert membership_request["properties"]["user_ids"]["maxItems"] == 1000
    assert "Existing disabled members can be retained unchanged" in membership_path["description"]
    assert "advances per-account Relay" in membership_path["description"]

    policy_path = paths["/admin/relay-groups/{group_id}/relay-policy"]
    policy_request = resolve_schema(
        policy_path["put"]["requestBody"]["content"]["application/json"]["schema"]
    )
    assert policy_request["additionalProperties"] is False
    assert policy_request["properties"]["expected_instance_policy_revision"]["minimum"] == 0
    assert policy_request["properties"]["allow_cidrs"]["maxItems"] == 256
    assert policy_request["properties"]["allow_ports"]["maxItems"] == 4096
    policy_response = resolve_schema(
        policy_path["get"]["responses"]["200"]["content"]["application/json"]["schema"]
    )
    assert set(policy_response["required"]) == {
        "inherited",
        "revision",
        "updated_at",
        "instance_policy_revision",
        "policy",
        "effective_policy",
    }
    policy_description = policy_path["get"]["description"]
    assert "enabled flags are ANDed" in policy_description
    assert "CIDR networks and" in policy_description and "intersected" in policy_description

    relay_ticket_description = paths["/relay/tickets"]["post"]["description"]
    assert "all assigned server-managed group" in relay_ticket_description
    relay_connect_description = paths["/relay/v1/connect"]["get"]["description"]
    assert "authorization revision" in relay_connect_description
    assert "close the user's current Relay sockets" in relay_connect_description


def test_relay_ticket_identity_is_session_derived_and_request_is_closed() -> None:
    operation = OPENAPI["paths"]["/relay/tickets"]["post"]
    request_schema = resolve_schema(
        operation["requestBody"]["content"]["application/json"]["schema"]
    )
    assert request_schema["additionalProperties"] is False
    assert set(request_schema["properties"]) == {"device_id", "target_host", "target_port"}
    assert "authenticated-user" in operation["description"]
    assert "caller-selected user_id" in operation["description"]
    assert "422" in operation["responses"]


def test_totp_mfa_contract_is_strict_and_keeps_password_login_sessionless() -> None:
    paths = OPENAPI["paths"]
    password_login = paths["/auth/login"]["post"]
    assert "202" in password_login["responses"]
    challenge = resolve_schema(
        password_login["responses"]["202"]["content"]["application/json"]["schema"]
    )
    assert challenge["additionalProperties"] is False
    assert set(challenge["required"]) == {"mfa_required", "challenge_id", "expires_at", "methods"}
    assert challenge["properties"]["mfa_required"]["const"] is True
    assert challenge["properties"]["expires_at"]["format"] == "date-time"
    methods = challenge["properties"]["methods"]
    assert methods["items"]["enum"] == ["totp", "recovery_code"]
    assert methods["minItems"] == methods["maxItems"] == 2
    session = resolve_schema(
        password_login["responses"]["200"]["content"]["application/json"]["schema"]
    )
    assert set(session["required"]) == {
        "account_id", "access_token", "expires_in", "refresh_token", "device_id", "vaults"
    }

    mfa_login = paths["/auth/login/mfa"]["post"]
    body = resolve_schema(mfa_login["requestBody"]["content"]["application/json"]["schema"])
    assert body["additionalProperties"] is False
    assert len(body["oneOf"]) == 2
    alternatives = [set(item["required"]) for item in body["oneOf"]]
    assert alternatives == [{"challenge_id", "totp_code"}, {"challenge_id", "recovery_code"}]
    assert "202" not in mfa_login["responses"]
    assert "200" in mfa_login["responses"] and "401" in mfa_login["responses"]
    assert "429" in mfa_login["responses"] and "503" in mfa_login["responses"]
    login_description = mfa_login["description"].lower()
    for phrase in ("single-use", "credential version", "five factor attempts", "mfa_key_unavailable", "recovery code"):
        assert phrase in login_description

    expected_shapes = [
        ("/auth/mfa", "get", "MfaStatus", {"enabled", "recovery_codes_remaining"}),
        ("/auth/mfa/totp/setup", "post", "MfaTotpSetup", {"secret", "provisioning_uri", "expires_at"}),
        ("/auth/mfa/totp/confirm", "post", "MfaRecoveryCodes", {"recovery_codes"}),
        ("/auth/mfa/recovery-codes", "post", "MfaRecoveryCodes", {"recovery_codes"}),
        ("/auth/mfa/totp", "delete", "MfaStatus", {"enabled", "recovery_codes_remaining"}),
    ]
    for path, method, schema_name, required in expected_shapes:
        operation = paths[path][method]
        status_code = "200"
        schema = resolve_schema(
            operation["responses"][status_code]["content"]["application/json"]["schema"]
        )
        assert schema["additionalProperties"] is False
        assert set(schema["required"]) == required
        assert "401" in operation["responses"]
        if method != "get":
            request_schema = resolve_schema(
                operation["requestBody"]["content"]["application/json"]["schema"]
            )
            assert request_schema["additionalProperties"] is False
        if schema_name == "MfaTotpSetup":
            assert schema["properties"]["secret"]["minLength"] == 32
            assert schema["properties"]["secret"]["pattern"] == "^[A-Z2-7]{32}$"
        if schema_name == "MfaRecoveryCodes":
            codes = schema["properties"]["recovery_codes"]
            assert codes["minItems"] == codes["maxItems"] == 10
            assert codes["uniqueItems"] is True
            assert codes["items"]["pattern"] == "^[A-Z2-7]{4}(?:-[A-Z2-7]{4}){3}$"


def test_refresh_response_contains_the_identity_required_by_clients() -> None:
    operation = OPENAPI["paths"]["/auth/refresh"]["post"]
    assert "401" in operation["responses"]
    assert "500" in operation["responses"]
    description = operation["description"].lower()
    assert "auth.refresh_reuse_detected" in description
    assert "revokes every session in that family whose revoked_at is null" in description
    assert "if the audit insert fails but the revocation transaction still commits" in description
    assert "if the transaction commit fails" in description
    assert "revocation outcome is unknown" in description
    assert "null actor ids" in description
    schema = resolve_schema(
        operation["responses"]["200"]["content"]["application/json"]["schema"]
    )
    assert schema["type"] == "object"
    assert schema["additionalProperties"] is False
    assert set(schema["required"]) == {
        "account_id",
        "device_id",
        "access_token",
        "expires_in",
        "refresh_token",
    }
    assert schema["properties"]["account_id"]["format"] == "uuid"
    assert schema["properties"]["device_id"]["format"] == "uuid"


def test_health_routes_override_the_global_api_server_prefix() -> None:
    global_servers = OPENAPI.get("servers", [])
    assert global_servers and global_servers[0].get("url") == "/api/v1"
    origin = "https://api.example.test"
    for path in ("/health/live", "/health/ready"):
        path_item = OPENAPI["paths"][path]
        servers = path_item.get("servers")
        assert servers and servers[0].get("url") == "/", (
            f"{path} must override the global /api/v1 server prefix"
        )
        effective_url = urljoin(origin, servers[0]["url"].rstrip("/") + path)
        assert urlparse(effective_url).path == path, (
            f"{path} resolves to the wrong health endpoint: {urlparse(effective_url).path}"
        )


def test_admin_vault_contract_bounds_pagination_and_quota_mutations() -> None:
    paths = OPENAPI["paths"]
    listing = paths["/admin/vaults"]["get"]
    parameters = {
        parameter["name"]: resolve_parameter(parameter)
        for parameter in listing.get("parameters", [])
    }
    assert set(parameters) == {"limit", "offset"}
    assert parameters["limit"]["schema"] == {
        "type": "integer",
        "minimum": 1,
        "maximum": 100,
        "default": 50,
    }
    assert parameters["offset"]["schema"] == {
        "type": "integer",
        "minimum": 0,
        "maximum": 1_000_000,
        "default": 0,
    }
    assert {"401", "403", "400"} <= set(listing["responses"])

    mutation = paths["/admin/vaults/{vault_id}/quota"]["put"]
    request = resolve_schema(
        mutation["requestBody"]["content"]["application/json"]["schema"]
    )
    assert request["additionalProperties"] is False
    assert request["properties"]["quota_bytes"]["type"] == "integer"
    assert request["properties"]["quota_bytes"]["minimum"] == 1
    assert request["properties"]["quota_bytes"]["maximum"] == 1_099_511_627_776
    assert {"400", "401", "403", "404", "409"} <= set(mutation["responses"])


def test_admin_audit_contract_is_instance_only_paginated_and_private() -> None:
    paths = OPENAPI["paths"]
    operation = paths["/admin/audit"]["get"]
    assert operation.get("requestBody") is None
    parameters = {
        parameter["name"]: resolve_parameter(parameter)
        for parameter in operation["parameters"]
    }
    assert set(parameters) == {"limit", "cursor"}
    assert parameters["limit"]["in"] == "query"
    assert parameters["limit"]["schema"]["default"] == 100
    assert parameters["limit"]["schema"]["minimum"] == 1
    assert parameters["limit"]["schema"]["maximum"] == 200
    assert parameters["cursor"]["in"] == "query"
    assert operation["x-implementation-status"] == "implemented"
    assert {"400", "401", "403", "410"} <= set(operation["responses"])

    page = resolve_schema(
        operation["responses"]["200"]["content"]["application/json"]["schema"]
    )
    assert page["additionalProperties"] is False
    assert set(page["required"]) == {"events", "next_cursor", "has_more"}
    event = resolve_schema(page["properties"]["events"]["items"])
    assert event["additionalProperties"] is False
    assert set(event["required"]) == {
        "event_id",
        "scope",
        "actor_user_id",
        "actor_device_id",
        "action",
        "resource_type",
        "resource_id",
        "result",
        "occurred_at",
        "source",
    }
    assert event["properties"]["scope"]["const"] == "instance"
    assert "vault_id" not in event["properties"]
    assert "HMAC" in event["properties"]["resource_id"]["description"]
    description = operation["description"].lower()
    assert "account- and vault-scope" in description
    assert "fixed high-water mark" in description
    assert "raw vault id" in description


def test_audit_contract_documents_atomic_logout_and_session_anonymization() -> None:
    operation = OPENAPI["paths"]["/audit"]["get"]
    description = operation["description"].lower()
    assert "auth.logout_succeeded" in description
    assert "same transaction" in description
    assert "unauthenticated or invalid logout attempts are not recorded" in description
    assert "session resource ids, and session-family resource ids are cleared" in description

    page = resolve_schema(
        operation["responses"]["200"]["content"]["application/json"]["schema"]
    )
    event = resolve_schema(page["properties"]["events"]["items"])
    resource_id = event["properties"]["resource_id"]
    assert "session and session_family resources expose only random uuids" in resource_id["description"].lower()
    assert "permanently purged" in resource_id["description"].lower()


def test_audit_contract_documents_recovery_resource_anonymization() -> None:
    operation = OPENAPI["paths"]["/audit"]["get"]
    description = operation["description"].lower()
    assert "auth.account_recovery_enabled" in description
    assert "resource_type=account_recovery" in description
    assert "cleared on permanent account purge" in description

    page = resolve_schema(
        operation["responses"]["200"]["content"]["application/json"]["schema"]
    )
    event = resolve_schema(page["properties"]["events"]["items"])
    resource_id = event["properties"]["resource_id"]["description"].lower()
    assert "account-recovery" in resource_id
    assert "permanently purged" in resource_id


def test_sync_batch_audit_contract_documents_atomic_privacy_boundary() -> None:
    operation = OPENAPI["paths"]["/audit"]["get"]
    description = operation["description"].lower()
    assert "vault.sync_batch_committed" in description
    assert "resource_type=sync_batch" in description
    assert "resource_id" in description and "null" in description
    assert "mixed batch" in description and "newly committed" in description
    assert "push transaction" in description
    page = resolve_schema(operation["responses"]["200"]["content"]["application/json"]["schema"])
    event = resolve_schema(page["properties"]["events"]["items"])
    assert "sync_batch" in event["properties"]["resource_type"]["description"]
    assert "sync batch events always use null" in event["properties"]["resource_id"]["description"].lower()

    audit_contract = API_CONTRACT.split("## Audit events", 1)[1].split("\n## ", 1)[0].lower()
    assert "vault.sync_batch_committed" in audit_contract
    assert "no record/op/revision identifier" in audit_contract
    assert "empty, failed, and fully idempotent pushes" in audit_contract
    assert "push transaction rolls back" in audit_contract


def test_audit_contract_documents_refresh_replay_detection_and_privacy() -> None:
    operation = OPENAPI["paths"]["/audit"]["get"]
    description = operation["description"].lower()
    assert "vault.conflict_resolved" in description
    assert "resource_type=conflict" in description
    assert "only the opaque conflict uuid" in description
    assert "retries, stale/unauthorized attempts, and failed resolutions emit no event" in description
    assert "audit insert failure rolls back resolution" in description
    assert "auth.refresh_reuse_detected" in description
    assert "when it revokes at least one session-family row whose revoked_at is null" in description
    assert "null actor ids" in description
    assert "best effort" in description
    assert "if the audit insert fails but the transaction commits" in description
    assert "if the transaction commit fails" in description
    assert "500 internal" in description
    assert "revocation outcome is unknown" in description
    assert "never the reused token" in description
    assert "session-family resource ids are cleared" in description

    response_schema = resolve_schema(
        operation["responses"]["200"]["content"]["application/json"]["schema"]
    )
    event = resolve_schema(response_schema["properties"]["events"]["items"])
    description = event["properties"]["resource_id"]["description"].lower()
    assert "session_family" in description
    assert "random uuids" in description


def test_admin_account_and_session_contract_is_bounded_and_secret_free() -> None:
    paths = OPENAPI["paths"]
    for path in (
        "/admin/accounts",
        "/admin/accounts/{user_id}/sessions",
    ):
        operation = paths[path]["get"]
        assert operation["x-implementation-status"] == "implemented"
        parameters = {
            parameter["name"]: resolve_parameter(parameter)
            for parameter in operation.get("parameters", [])
        }
        assert {"limit", "offset"} <= set(parameters)
        assert parameters["limit"]["schema"]["minimum"] == 1
        assert parameters["limit"]["schema"]["maximum"] == 100
        assert parameters["offset"]["schema"]["maximum"] == 1_000_000
        assert {"400", "401", "403"} <= set(operation["responses"])

    accounts = paths["/admin/accounts"]["get"]
    page = resolve_schema(
        accounts["responses"]["200"]["content"]["application/json"]["schema"]
    )
    account = resolve_schema(page["properties"]["accounts"]["items"])
    assert set(account["required"]) == {
        "user_id",
        "username",
        "status",
        "created_at",
        "active_device_count",
        "active_session_count",
    }
    assert account["properties"]["status"]["enum"] == ["active", "disabled", "deleting"]
    assert "account_key_envelope" not in account["properties"]

    status = paths["/admin/accounts/{user_id}/status"]["put"]
    assert status["x-implementation-status"] == "implemented"
    request = resolve_schema(
        status["requestBody"]["content"]["application/json"]["schema"]
    )
    assert request["additionalProperties"] is False
    assert request["properties"]["status"]["enum"] == ["active", "disabled"]
    assert {"400", "401", "403", "404", "409"} <= set(status["responses"])

    sessions = paths["/admin/accounts/{user_id}/sessions"]["get"]
    session_page = resolve_schema(
        sessions["responses"]["200"]["content"]["application/json"]["schema"]
    )
    session = resolve_schema(session_page["properties"]["sessions"]["items"])
    assert set(session["required"]) == {
        "session_id",
        "device_id",
        "device_name",
        "created_at",
        "access_expires_at",
        "refresh_expires_at",
        "revoked_at",
        "active",
    }
    assert not {"access_hash", "refresh_hash", "access_token", "refresh_token", "remote_addr"} & set(
        session["properties"]
    )

    for path in (
        "/admin/accounts/{user_id}/sessions/revoke",
        "/admin/accounts/{user_id}/sessions/{session_id}/revoke",
    ):
        operation = paths[path]["post"]
        assert operation["x-implementation-status"] == "implemented"
        assert {"400", "401", "403", "404", "409"} <= set(operation["responses"])


def test_admin_backup_status_contract_is_fixed_and_secret_free() -> None:
    path_item = OPENAPI["paths"]["/admin/backup-status"]
    assert set(path_item) == {"get"}
    operation = path_item["get"]
    assert operation.get("requestBody") is None
    assert {"200", "401", "403"} <= set(operation["responses"])
    description = operation["description"].lower()
    assert "verify-backup` does not change this status" in description
    assert "shared instance-admin ledger" in description
    assert "size unknown" in description
    assert "no archive or key paths" in description

    response = resolve_schema(
        operation["responses"]["200"]["content"]["application/json"]["schema"]
    )
    assert response["additionalProperties"] is False
    assert set(response["required"]) == {"operation", "last_attempt"}
    assert response["properties"]["operation"]["const"] == "backup"
    variants = response["properties"]["last_attempt"]["oneOf"]
    assert any(variant.get("type") == "null" for variant in variants)
    attempt_variants = [variant for variant in variants if "$ref" in variant]
    assert len(attempt_variants) == 1
    attempt = resolve_schema(attempt_variants[0])
    assert attempt["additionalProperties"] is False
    assert set(attempt["required"]) == {
        "attempted_at",
        "result",
        "migration_version",
        "archive_bytes",
        "failure_category",
    }
    properties = attempt["properties"]
    assert properties["result"]["enum"] == ["succeeded", "failed"]
    assert properties["failure_category"]["enum"] == ["backup_failed", None]
    assert properties["migration_version"]["type"] == ["integer", "null"]
    assert properties["archive_bytes"]["type"] == ["integer", "null"]
    assert not {
        "archive_path",
        "key_path",
        "key",
        "policy",
        "error",
        "error_message",
    } & set(properties)


def test_admin_backup_replication_status_contract_is_fixed_and_secret_free() -> None:
    operation = OPENAPI["paths"]["/admin/backup-replication"]["get"]
    assert operation.get("requestBody") is None
    assert {"200", "401", "403"} <= set(operation["responses"])
    response = resolve_schema(
        operation["responses"]["200"]["content"]["application/json"]["schema"]
    )
    assert response["additionalProperties"] is False
    assert set(response["required"]) == {
        "operation", "configured", "pending_count", "latest_attempt"
    }
    assert response["properties"]["operation"]["const"] == "backup_replication"
    assert response["properties"]["pending_count"]["minimum"] == 0
    variants = response["properties"]["latest_attempt"]["oneOf"]
    assert any(variant.get("type") == "null" for variant in variants)
    attempts = [resolve_schema(variant) for variant in variants if "$ref" in variant]
    assert len(attempts) == 1
    attempt = attempts[0]
    assert attempt["additionalProperties"] is False
    assert set(attempt["required"]) == {
        "archive_id", "state", "attempted_at", "completed_at", "archive_bytes",
        "failure_category",
    }
    assert attempt["properties"]["failure_category"]["enum"] == [
        "archive_unavailable", "credentials_invalid", "remote_unavailable",
        "remote_integrity_mismatch", "replication_failed", None,
    ]
    assert not {
        "endpoint", "bucket", "prefix", "object_key", "credential_path", "credentials",
        "error", "error_message",
    } & set(attempt["properties"])


def test_admin_backup_replication_preflight_contract_is_empty_and_fixed() -> None:
    operation = OPENAPI["paths"]["/admin/backup-replication/preflight"]["post"]
    assert {"200", "400", "401", "403", "502", "503"} <= set(
        operation["responses"]
    )
    request = resolve_schema(
        operation["requestBody"]["content"]["application/json"]["schema"]
    )
    assert request["type"] == "object"
    assert request["additionalProperties"] is False
    assert request["maxProperties"] == 0

    response = resolve_schema(
        operation["responses"]["200"]["content"]["application/json"]["schema"]
    )
    assert response["type"] == "object"
    assert response["additionalProperties"] is False
    assert response["required"] == ["check", "result"]
    assert response["properties"]["check"]["const"] == "bucket_access"
    assert response["properties"]["result"]["const"] == "passed"
    assert "HeadBucket" in operation["description"]
    assert "multipart" in operation["description"]


def test_admin_backup_schedule_contract_is_durable_and_secret_free() -> None:
    path_item = OPENAPI["paths"]["/admin/backup-schedule"]
    assert set(path_item) == {"get", "put"}
    get_operation = path_item["get"]
    assert {"200", "401", "403"} <= set(get_operation["responses"])
    assert "backup_configured" in get_operation["description"]
    assert "interrupted" in get_operation["description"]

    put_operation = path_item["put"]
    assert {"200", "400", "401", "403", "503"} <= set(put_operation["responses"])
    assert "shared operation lock" in put_operation["description"]
    request = resolve_schema(
        put_operation["requestBody"]["content"]["application/json"]["schema"]
    )
    assert request["additionalProperties"] is False
    assert request["required"] == ["interval_hours"]
    assert request["properties"]["interval_hours"]["minimum"] == 1
    assert request["properties"]["interval_hours"]["maximum"] == 720
    assert request["properties"]["interval_hours"]["type"] == ["integer", "null"]

    response = resolve_schema(
        get_operation["responses"]["200"]["content"]["application/json"]["schema"]
    )
    assert response["additionalProperties"] is False
    assert set(response["required"]) == {
        "operation",
        "backup_configured",
        "interval_hours",
        "next_run_at",
        "last_run",
    }
    assert response["properties"]["operation"]["const"] == "backup_schedule"
    last_run_variants = response["properties"]["last_run"]["oneOf"]
    assert any(variant.get("type") == "null" for variant in last_run_variants)
    run_refs = [variant for variant in last_run_variants if "$ref" in variant]
    assert len(run_refs) == 1
    run = resolve_schema(run_refs[0])
    assert run["additionalProperties"] is False
    assert set(run["required"]) == {
        "run_id",
        "scheduled_for",
        "started_at",
        "finished_at",
        "status",
        "result_code",
        "archive_bytes",
        "migration_version",
    }
    assert run["properties"]["status"]["enum"] == [
        "running",
        "succeeded",
        "failed",
        "interrupted",
    ]
    assert run["properties"]["result_code"]["enum"] == [
        "completed",
        "backup_failed",
        "interrupted",
        None,
    ]
    assert not {
        "archive_path",
        "key_path",
        "key",
        "error",
        "error_message",
    } & set(run["properties"])


def test_admin_backup_job_contract_is_allowlisted_and_server_configured() -> None:
    operation = OPENAPI["paths"]["/admin/jobs"]["post"]
    assert {"202", "400", "401", "403", "409", "503"} <= set(operation["responses"])
    request_schema = resolve_schema(
        operation["requestBody"]["content"]["application/json"]["schema"]
    )
    assert len(request_schema["oneOf"]) == 3
    request_variants = [resolve_schema(variant) for variant in request_schema["oneOf"]]
    assert all(variant["additionalProperties"] is False for variant in request_variants)
    assert {
        variant["properties"]["action"]["const"]: set(variant["required"])
        for variant in request_variants
    } == {
        "maintenance": {"request_id", "action"},
        "backup": {"request_id", "action"},
        "restore": {"request_id", "action", "archive_id", "archive_source"},
    }
    assert "ATERMIUS_BACKUP_ARCHIVE_DIR" in operation["description"]
    assert "ATERMIUS_BACKUP_KEY_FILE" in operation["description"]
    assert "503 BACKUP_NOT_CONFIGURED" in operation["description"]
    assert "RESTORE_SOURCE_UNAVAILABLE" in operation["responses"]["409"]["description"]
    assert "never contain paths" in operation["description"]

    job_schema = resolve_schema(
        OPENAPI["components"]["schemas"]["AdminJob"]["properties"]["action"]
    )
    assert job_schema["enum"] == ["maintenance", "backup", "restore"]
    job = OPENAPI["components"]["schemas"]["AdminJob"]
    assert "archive_id" in job["required"]
    assert job["properties"]["archive_id"]["type"] == ["string", "null"]
    result_schema = OPENAPI["components"]["schemas"]["AdminJob"]["properties"][
        "result_code"
    ]
    assert "backup_failed" in result_schema["enum"]
    assert "restore_failed" in result_schema["enum"]


def test_admin_restore_source_catalog_is_bounded_and_path_free() -> None:
    operation = OPENAPI["paths"]["/admin/restore-sources"]["get"]
    assert {"200", "401", "403", "503"} <= set(operation["responses"])
    assert "server-generated" in operation["description"]
    assert "never exposes archive filenames, paths, key material" in operation["description"]

    page = OPENAPI["components"]["schemas"]["AdminRestoreSourcePage"]
    assert page["additionalProperties"] is False
    assert set(page["required"]) == {"sources", "total"}
    source = resolve_schema(page["properties"]["sources"]["items"])
    assert source["additionalProperties"] is False
    assert set(source["required"]) == {
        "archive_id",
        "created_at",
        "archive_bytes",
        "origin",
        "source",
    }
    assert source["properties"]["origin"]["enum"] == ["manual", "scheduled"]
    assert source["properties"]["source"]["enum"] == ["local", "replica"]
    assert source["properties"]["archive_bytes"]["minimum"] == 1
    assert not {
        "path",
        "archive_path",
        "basename",
        "key",
        "key_file",
        "error",
    } & set(source["properties"])

    jobs_description = OPENAPI["paths"]["/admin/jobs"]["post"]["description"]
    assert "prepares a separate directory" in jobs_description
    assert "never activates or replaces" in jobs_description
    assert "--server-stopped" in jobs_description
