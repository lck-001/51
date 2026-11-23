/// This state expresses local authorization, not a verified assistant brand,
/// model execution, learning confirmation or publication.
enum AgentBridgePhase { disabled, enabled, draining, closed }

enum AgentBridgeErrorCode {
  unsupportedPlatform,
  rootBusy,
  rootUnavailable,
  privateStorageUnavailable,
  ownerMismatch,
  disabled,
  forbidden,
  expired,
  revoked,
  invalidRequest,
  invalidJson,
  sessionUnconfirmed,
  unsupportedMedia,
  sourceMismatch,
  sourceTooLarge,
  tooLarge,
  busy,
  timeout,
  outcomeUnknown,
  deliveryConflict,
  candidateLimitExceeded,
  capacityExceeded,
  recoveryHold,
  unavailable,
  closed,
}

final class AgentBridgeException implements Exception {
  const AgentBridgeException(this.code);
  final AgentBridgeErrorCode code;
  @override
  String toString() => 'AgentBridgeException(${code.name})';
}

final class AgentBridgeGrantRequest {
  const AgentBridgeGrantRequest({
    required this.materialVersionId,
    this.allowSourceRead = false,
  });
  final String materialVersionId;
  final bool allowSourceRead;
}

/// Generic UI state contains no endpoint, source text, token or private path.
final class AgentBridgeStatus {
  const AgentBridgeStatus({
    required this.phase,
    this.materialId,
    this.materialVersionId,
    this.integrationId,
    this.expiresAtUtc,
    this.allowSourceRead = false,
    this.inFlight = 0,
    this.lastCandidateId,
    this.errorCode,
  });
  final AgentBridgePhase phase;
  final String? materialId, materialVersionId, integrationId;
  final DateTime? expiresAtUtc;
  final bool allowSourceRead;
  final int inFlight;
  final String? lastCandidateId;
  final String? errorCode;
}

/// Available only through the owner's explicit advanced setup action. The
/// descriptor locator is private setup data; the template contains no secret.
/// Never send this object to an MCP tool response or ordinary diagnostic log.
final class AgentBridgeSetup {
  const AgentBridgeSetup({
    required this.descriptorPath,
    required this.configurationToml,
    required this.instructions,
  });
  final String descriptorPath;
  final String configurationToml;
  final String instructions;
}
