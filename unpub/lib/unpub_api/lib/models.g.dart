// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'models.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ListApi _$ListApiFromJson(Map<String, dynamic> json) => ListApi(
      (json['count'] as num).toInt(),
      (json['packages'] as List<dynamic>)
          .map((e) => ListApiPackage.fromJson(e as Map<String, dynamic>))
          .toList(),
    );

Map<String, dynamic> _$ListApiToJson(ListApi instance) => <String, dynamic>{
      'count': instance.count,
      'packages': instance.packages,
    };

ListApiPackage _$ListApiPackageFromJson(Map<String, dynamic> json) =>
    ListApiPackage(
      json['name'] as String,
      json['description'] as String?,
      (json['tags'] as List<dynamic>).map((e) => e as String).toList(),
      json['latest'] as String,
      DateTime.parse(json['updatedAt'] as String),
    );

Map<String, dynamic> _$ListApiPackageToJson(ListApiPackage instance) =>
    <String, dynamic>{
      'name': instance.name,
      'description': instance.description,
      'tags': instance.tags,
      'latest': instance.latest,
      'updatedAt': instance.updatedAt.toIso8601String(),
    };

DetailViewVersion _$DetailViewVersionFromJson(Map<String, dynamic> json) =>
    DetailViewVersion(
      json['version'] as String,
      DateTime.parse(json['createdAt'] as String),
    );

Map<String, dynamic> _$DetailViewVersionToJson(DetailViewVersion instance) =>
    <String, dynamic>{
      'version': instance.version,
      'createdAt': instance.createdAt.toIso8601String(),
    };

DependencyView _$DependencyViewFromJson(Map<String, dynamic> json) =>
    DependencyView(
      json['name'] as String,
      url: json['url'] as String?,
      internal: json['internal'] as bool? ?? false,
    );

Map<String, dynamic> _$DependencyViewToJson(DependencyView instance) =>
    <String, dynamic>{
      'name': instance.name,
      'url': instance.url,
      'internal': instance.internal,
    };

WebapiDetailView _$WebapiDetailViewFromJson(Map<String, dynamic> json) =>
    WebapiDetailView(
      json['name'] as String,
      json['version'] as String,
      json['description'] as String,
      json['homepage'] as String,
      (json['uploaders'] as List<dynamic>).map((e) => e as String).toList(),
      DateTime.parse(json['createdAt'] as String),
      json['readme'] as String?,
      json['changelog'] as String?,
      (json['versions'] as List<dynamic>)
          .map((e) => DetailViewVersion.fromJson(e as Map<String, dynamic>))
          .toList(),
      (json['authors'] as List<dynamic>).map((e) => e as String).toList(),
      (json['dependencies'] as List<dynamic>?)
          ?.map((e) => DependencyView.fromJson(e as Map<String, dynamic>))
          .toList(),
      (json['tags'] as List<dynamic>).map((e) => e as String).toList(),
      hasDocs: json['hasDocs'] as bool? ?? false,
    );

Map<String, dynamic> _$WebapiDetailViewToJson(WebapiDetailView instance) =>
    <String, dynamic>{
      'name': instance.name,
      'version': instance.version,
      'description': instance.description,
      'homepage': instance.homepage,
      'uploaders': instance.uploaders,
      'createdAt': instance.createdAt.toIso8601String(),
      'readme': instance.readme,
      'changelog': instance.changelog,
      'versions': instance.versions,
      'authors': instance.authors,
      'dependencies': instance.dependencies,
      'tags': instance.tags,
      'hasDocs': instance.hasDocs,
    };

AccountView _$AccountViewFromJson(Map<String, dynamic> json) => AccountView(
      json['id'] as String,
      json['email'] as String,
      json['name'] as String,
      (json['groups'] as List<dynamic>).map((e) => e as String).toList(),
      json['isAdmin'] as bool,
      json['csrfToken'] as String,
      json['currentSessionId'] as String,
      (json['sessions'] as List<dynamic>)
          .map((e) => AccountSession.fromJson(e as Map<String, dynamic>))
          .toList(),
      (json['tokens'] as List<dynamic>)
          .map((e) => AccountToken.fromJson(e as Map<String, dynamic>))
          .toList(),
      (json['serviceTokens'] as List<dynamic>)
          .map((e) => AccountToken.fromJson(e as Map<String, dynamic>))
          .toList(),
      json['pubApiProtected'] as bool,
      json['publicUrl'] as String,
    );

Map<String, dynamic> _$AccountViewToJson(AccountView instance) =>
    <String, dynamic>{
      'id': instance.id,
      'email': instance.email,
      'name': instance.name,
      'groups': instance.groups,
      'isAdmin': instance.isAdmin,
      'csrfToken': instance.csrfToken,
      'currentSessionId': instance.currentSessionId,
      'sessions': instance.sessions,
      'tokens': instance.tokens,
      'serviceTokens': instance.serviceTokens,
      'pubApiProtected': instance.pubApiProtected,
      'publicUrl': instance.publicUrl,
    };

AccountSession _$AccountSessionFromJson(Map<String, dynamic> json) =>
    AccountSession(
      json['id'] as String,
      json['ip'] as String,
      (json['previousIps'] as List<dynamic>).map((e) => e as String).toList(),
      DateTime.parse(json['createdAt'] as String),
      DateTime.parse(json['lastSeenAt'] as String),
      DateTime.parse(json['expiresAt'] as String),
    );

Map<String, dynamic> _$AccountSessionToJson(AccountSession instance) =>
    <String, dynamic>{
      'id': instance.id,
      'ip': instance.ip,
      'previousIps': instance.previousIps,
      'createdAt': instance.createdAt.toIso8601String(),
      'lastSeenAt': instance.lastSeenAt.toIso8601String(),
      'expiresAt': instance.expiresAt.toIso8601String(),
    };

AccountToken _$AccountTokenFromJson(Map<String, dynamic> json) => AccountToken(
      json['id'] as String,
      json['name'] as String,
      json['kind'] as String,
      json['email'] as String,
      json['createdBy'] as String,
      DateTime.parse(json['createdAt'] as String),
      json['expiresAt'] == null
          ? null
          : DateTime.parse(json['expiresAt'] as String),
      json['lastUsedAt'] == null
          ? null
          : DateTime.parse(json['lastUsedAt'] as String),
      json['lastUsedIp'] as String?,
    );

Map<String, dynamic> _$AccountTokenToJson(AccountToken instance) =>
    <String, dynamic>{
      'id': instance.id,
      'name': instance.name,
      'kind': instance.kind,
      'email': instance.email,
      'createdBy': instance.createdBy,
      'createdAt': instance.createdAt.toIso8601String(),
      'expiresAt': instance.expiresAt?.toIso8601String(),
      'lastUsedAt': instance.lastUsedAt?.toIso8601String(),
      'lastUsedIp': instance.lastUsedIp,
    };

CreatedToken _$CreatedTokenFromJson(Map<String, dynamic> json) => CreatedToken(
      AccountToken.fromJson(json['token'] as Map<String, dynamic>),
      json['value'] as String,
    );

Map<String, dynamic> _$CreatedTokenToJson(CreatedToken instance) =>
    <String, dynamic>{
      'token': instance.token,
      'value': instance.value,
    };

AdminView _$AdminViewFromJson(Map<String, dynamic> json) => AdminView(
      json['csrfToken'] as String,
      json['viewerId'] as String,
      (json['users'] as List<dynamic>)
          .map((e) => AdminUser.fromJson(e as Map<String, dynamic>))
          .toList(),
      truncated: json['truncated'] as bool? ?? false,
    );

Map<String, dynamic> _$AdminViewToJson(AdminView instance) => <String, dynamic>{
      'csrfToken': instance.csrfToken,
      'viewerId': instance.viewerId,
      'users': instance.users,
      'truncated': instance.truncated,
    };

AdminUser _$AdminUserFromJson(Map<String, dynamic> json) => AdminUser(
      json['id'] as String,
      json['email'] as String,
      json['name'] as String,
      (json['groups'] as List<dynamic>).map((e) => e as String).toList(),
      json['status'] as String,
      json['blockedReason'] as String?,
      (json['liveSessions'] as num).toInt(),
      json['lastValidatedAt'] == null
          ? null
          : DateTime.parse(json['lastValidatedAt'] as String),
    );

Map<String, dynamic> _$AdminUserToJson(AdminUser instance) => <String, dynamic>{
      'id': instance.id,
      'email': instance.email,
      'name': instance.name,
      'groups': instance.groups,
      'status': instance.status,
      'blockedReason': instance.blockedReason,
      'liveSessions': instance.liveSessions,
      'lastValidatedAt': instance.lastValidatedAt?.toIso8601String(),
    };
