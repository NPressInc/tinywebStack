class MobilizonActor {
  MobilizonActor({
    required this.id,
    this.name,
    this.preferredUsername,
    this.domain,
  });

  final String id;
  final String? name;
  final String? preferredUsername;
  final String? domain;

  String get displayLabel {
    if (name != null && name!.isNotEmpty) {
      return name!;
    }
    if (preferredUsername != null && preferredUsername!.isNotEmpty) {
      if (domain != null && domain!.isNotEmpty) {
        return '$preferredUsername@$domain';
      }
      return preferredUsername!;
    }
    return 'Organizer';
  }

  factory MobilizonActor.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return MobilizonActor(id: '');
    }
    return MobilizonActor(
      id: json['id'] as String? ?? '',
      name: json['name'] as String?,
      preferredUsername: json['preferredUsername'] as String?,
      domain: json['domain'] as String?,
    );
  }
}

class MobilizonAddress {
  MobilizonAddress({this.description, this.locality});

  final String? description;
  final String? locality;

  String get label {
    final parts = <String>[];
    if (description != null && description!.trim().isNotEmpty) {
      parts.add(description!.trim());
    }
    if (locality != null && locality!.trim().isNotEmpty) {
      parts.add(locality!.trim());
    }
    return parts.join(', ');
  }

  factory MobilizonAddress.fromJson(Map<String, dynamic>? json) {
    if (json == null) {
      return MobilizonAddress();
    }
    return MobilizonAddress(
      description: json['description'] as String?,
      locality: json['locality'] as String?,
    );
  }
}

class MobilizonEventSummary {
  MobilizonEventSummary({
    required this.id,
    required this.uuid,
    required this.title,
    this.beginsOn,
    this.endsOn,
    this.description,
    this.visibility,
    required this.organizer,
    required this.attributedTo,
    required this.physicalAddress,
    this.goingCount,
    this.myParticipationId,
    this.myRole,
  });

  final String id;
  final String uuid;
  final String title;
  final DateTime? beginsOn;
  final DateTime? endsOn;
  final String? description;
  final String? visibility;
  final MobilizonActor organizer;
  final MobilizonActor attributedTo;
  final MobilizonAddress physicalAddress;
  final int? goingCount;
  final String? myParticipationId;
  final String? myRole;

  bool get isJoined => myParticipationId != null && myParticipationId!.isNotEmpty;

  bool get isFederated {
    final domain = attributedTo.domain ?? organizer.domain;
    return domain != null && domain.isNotEmpty;
  }

  factory MobilizonEventSummary.fromSearchJson(Map<String, dynamic> json) {
    final stats = json['participantStats'] as Map<String, dynamic>?;
    return MobilizonEventSummary(
      id: json['id'] as String? ?? '',
      uuid: json['uuid'] as String? ?? '',
      title: json['title'] as String? ?? '',
      beginsOn: _parseDate(json['beginsOn']),
      endsOn: _parseDate(json['endsOn']),
      description: json['description'] as String?,
      visibility: json['visibility'] as String?,
      organizer: MobilizonActor.fromJson(
        json['organizerActor'] as Map<String, dynamic>?,
      ),
      attributedTo: MobilizonActor.fromJson(
        json['attributedTo'] as Map<String, dynamic>?,
      ),
      physicalAddress: MobilizonAddress.fromJson(
        json['physicalAddress'] as Map<String, dynamic>?,
      ),
      goingCount: stats?['going'] as int?,
    );
  }

  MobilizonEventSummary copyWithParticipation({
    String? participationId,
    String? role,
    bool clearParticipation = false,
  }) {
    return MobilizonEventSummary(
      id: id,
      uuid: uuid,
      title: title,
      beginsOn: beginsOn,
      endsOn: endsOn,
      description: description,
      visibility: visibility,
      organizer: organizer,
      attributedTo: attributedTo,
      physicalAddress: physicalAddress,
      goingCount: goingCount,
      myParticipationId:
          clearParticipation ? null : (participationId ?? myParticipationId),
      myRole: clearParticipation ? null : (role ?? myRole),
    );
  }
}

DateTime? _parseDate(Object? raw) {
  if (raw is! String || raw.isEmpty) {
    return null;
  }
  return DateTime.tryParse(raw);
}
