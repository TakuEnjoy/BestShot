class BackgroundTask {
  BackgroundTask({required this.id, required this.title, required this.total});
  final String id;
  final String title;
  final int total;
  double progress = 0.0;
  String statusText = '準備中...';
}
