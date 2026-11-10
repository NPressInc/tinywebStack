class SetupStep {
  const SetupStep({
    required this.id,
    required this.label,
    required this.state,
    this.detail = '',
  });

  final String id;
  final String label;
  final String state;
  final String detail;

  factory SetupStep.fromJson(Map<String, dynamic> json) {
    return SetupStep(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? '',
      state: json['state'] as String? ?? 'pending',
      detail: json['detail'] as String? ?? '',
    );
  }
}

class SetupStatus {
  const SetupStatus({
    required this.phase,
    required this.provisioned,
    required this.codeRequired,
    required this.steps,
    this.familySlug,
    this.domain,
    this.parentUsername,
    this.error,
    this.enrollOrigin,
  });

  final String phase;
  final bool provisioned;
  final bool codeRequired;
  final List<SetupStep> steps;
  final String? familySlug;
  final String? domain;
  final String? parentUsername;
  final String? error;
  final String? enrollOrigin;

  bool get isProgress =>
      phase == 'installing' || phase == 'blocked' || phase == 'failed' || phase == 'ready';

  factory SetupStatus.fromJson(Map<String, dynamic> json) {
    final rawSteps = json['steps'];
    final steps = <SetupStep>[];
    if (rawSteps is List) {
      for (final item in rawSteps) {
        if (item is Map<String, dynamic>) {
          steps.add(SetupStep.fromJson(item));
        } else if (item is Map) {
          steps.add(SetupStep.fromJson(Map<String, dynamic>.from(item)));
        }
      }
    }
    return SetupStatus(
      phase: json['phase'] as String? ?? 'waiting',
      provisioned: json['provisioned'] as bool? ?? false,
      codeRequired: json['code_required'] as bool? ?? false,
      steps: steps,
      familySlug: json['family_slug'] as String?,
      domain: json['domain'] as String?,
      parentUsername: json['parent_username'] as String?,
      error: json['error'] as String?,
      enrollOrigin: json['enroll_origin'] as String?,
    );
  }
}

class SetupException implements Exception {
  SetupException(this.message);
  final String message;
}
