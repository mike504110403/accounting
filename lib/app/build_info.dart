/// build 戳記（tool/build_web.sh 以 --dart-define 注入）；設定頁底顯示，
/// 用來分辨手機上跑的是哪一版（Flutter Web service worker 換版要第二次載入才生效）。
library;

const kBuildStamp = String.fromEnvironment('BUILD_STAMP', defaultValue: 'dev');
