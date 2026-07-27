import 'package:json_annotation/json_annotation.dart';

part 'models.g.dart';

@JsonSerializable()
class ListApi {
  int count;
  List<ListApiPackage> packages;

  ListApi(this.count, this.packages);

  factory ListApi.fromJson(Map<String, dynamic> map) => _$ListApiFromJson(map);
  Map<String, dynamic> toJson() => _$ListApiToJson(this);
}

@JsonSerializable()
class ListApiPackage {
  String name;
  String? description;
  List<String> tags;
  String latest;
  DateTime updatedAt;

  ListApiPackage(
      this.name, this.description, this.tags, this.latest, this.updatedAt);

  factory ListApiPackage.fromJson(Map<String, dynamic> map) =>
      _$ListApiPackageFromJson(map);
  Map<String, dynamic> toJson() => _$ListApiPackageToJson(this);
}

@JsonSerializable()
class DetailViewVersion {
  String version;
  DateTime createdAt;

  DetailViewVersion(this.version, this.createdAt);

  factory DetailViewVersion.fromJson(Map<String, dynamic> map) =>
      _$DetailViewVersionFromJson(map);

  Map<String, dynamic> toJson() => _$DetailViewVersionToJson(this);
}

@JsonSerializable()
class DependencyView {
  /// Package name.
  String name;

  /// Absolute URL to the dependency's page on an external pub server
  /// (e.g. pub.dev or another hosted server).
  ///
  /// `null` when [internal] is `true`, or when the dependency is not linkable
  /// to a pub page (sdk/git/path sources).
  String? url;

  /// `true` when the dependency is hosted on this server and should be linked
  /// with an internal router link.
  bool internal;

  DependencyView(this.name, {this.url, this.internal = false});

  factory DependencyView.fromJson(Map<String, dynamic> map) =>
      _$DependencyViewFromJson(map);

  Map<String, dynamic> toJson() => _$DependencyViewToJson(this);
}

@JsonSerializable()
class WebapiDetailView {
  String name;
  String version;
  String description;
  String homepage;
  List<String> uploaders;
  DateTime createdAt;
  final String? readme;
  final String? changelog;
  List<DetailViewVersion> versions;
  List<String> authors;
  List<DependencyView>? dependencies;
  List<String> tags;

  /// Whether this server can serve generated API documentation for this
  /// package (i.e. a doc store is configured). Controls the "API reference"
  /// link in the web UI.
  bool hasDocs;

  WebapiDetailView(
      this.name,
      this.version,
      this.description,
      this.homepage,
      this.uploaders,
      this.createdAt,
      this.readme,
      this.changelog,
      this.versions,
      this.authors,
      this.dependencies,
      this.tags,
      {this.hasDocs = false});

  factory WebapiDetailView.fromJson(Map<String, dynamic> map) =>
      _$WebapiDetailViewFromJson(map);

  Map<String, dynamic> toJson() => _$WebapiDetailViewToJson(this);
}
