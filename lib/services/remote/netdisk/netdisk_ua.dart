// ⛔ 聚合网盘（夸克 / 阿里云盘）功能暂时下线 —— 2026-09-30。
// 原因：登录后进入目录仍有问题，暂不随正式版发布，代码原样保留待下次完善。
// 本文件目前已无生效引用（不参与构建）；恢复步骤见
// lib/services/network_connections_service.dart 文件头的说明。
/// 网盘（夸克 / 阿里云盘）用到的 User-Agent 常量，集中一处定义。
///
/// ## 为什么必须集中
///
/// 各家网盘都对 UA 敏感，且**两种场合要的是不同的 UA**：
///
/// | 场合 | 该用的 UA | 原因 |
/// |---|---|---|
/// | 夸克：登录 WebView **和**接口请求 | [quarkClient] | 夸克官方 PC 端本身是 Chromium/Electron 套壳，其登录页与接口共用这一串；两家都把会话与 UA 绑定，不一致就 401 |
/// | 阿里：登录 WebView | [desktop] | 网页版按 UA 区分「登录界面」与「App 推广页」，移动端 UA 会命中推广页 |
/// | 阿里：接口请求 | **待定**（P2 换到网页版体系时一并定） | 网页版体系要配 `aliyun-sdk-js/...` 之类的 UA |
///
/// 历史缺陷：登录 WebView 写死 `Chrome/120`，客户端请求写死 `Chrome/134`，
/// 两处各写一份 ⇒ 改一处忘一处。现在统一到这里，
/// **任何地方再写死 UA 字符串都是 bug**。
class NetdiskUserAgent {
  NetdiskUserAgent._();

  /// 桌面版 Chrome UA —— 给**登录 WebView**用。
  static const String desktop = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36';

  /// 夸克 PC 客户端 UA —— 给**文件接口**用（与参考实现一致）。
  static const String quarkClient =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) quark-cloud-drive/2.5.20 '
      'Chrome/100.0.4896.160 Electron/18.3.5.12-a038f7b798 '
      'Safari/537.36 Channel/pckk_other_ch';
}
