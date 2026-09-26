class RecentProject {
  const RecentProject({required this.path, required this.lastOpenedAt});

  final String path;
  final DateTime lastOpenedAt;

  String get displayName => path.split(RegExp(r'[\\/]')).where((s) => s.isNotEmpty).last;

  Map<String, dynamic> toJson() => {
        'path': path,
        'lastOpenedAt': lastOpenedAt.toIso8601String(),
      };

  factory RecentProject.fromJson(Map<String, dynamic> json) => RecentProject(
        path: json['path'] as String,
        lastOpenedAt: DateTime.parse(json['lastOpenedAt'] as String),
      );
}
