import 'package:flutter/material.dart';

import '../../core/utils.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../services/install_status_service.dart';

/// 安装包（APK / XAPK / APKS / APKM / AAB）图标下方的「已安装 / 未安装」标识。
///
/// 渲染规则：
/// - 非安装包 / 远程文件 / 加密文件 → 不渲染（不占位）；
/// - 原生查询尚未返回、或无法判定（损坏包、不认识的容器）→ 不渲染（留白，避免先闪一个错的值）；
/// - 已安装 → 绿色实心标签；未安装 → 中性描边标签。
///
/// 同一个 [path] 在同一帧内多次构建只会登记一次查询（见 [InstallStatusCache]）。
class InstallStatusBadge extends StatelessWidget {
  /// 文件绝对路径（远程路径以 `remote://` 开头，会被跳过）。
  final String path;

  /// 文件大小与修改时间参与「指纹」计算：文件被替换后自动重查。
  final int size;
  final int modifiedMs;

  /// 与所在列表 / 网格的图标缩放保持一致。
  final double scale;

  /// 紧凑模式（双栏等窄条目）：更小字号与内边距。
  final bool compact;

  /// 限宽（一般传图标宽度）。传了就把它压进这个宽度内（必要时整体缩放），
  /// 避免德语 / 俄语这类长文案把列表左侧图标列撑宽、把文件名挤走。
  final double? maxWidth;

  const InstallStatusBadge({
    super.key,
    required this.path,
    required this.size,
    required this.modifiedMs,
    this.scale = 1.0,
    this.compact = false,
    this.maxWidth,
  });

  @override
  Widget build(BuildContext context) {
    if (!FileUtils.isInstallPackage(path)) return const SizedBox.shrink();
    if (path.startsWith('remote://') || path.startsWith('cryptremote://')) {
      return const SizedBox.shrink();
    }
    InstallStatusCache.instance.request(path, size, modifiedMs);
    return ValueListenableBuilder<int>(
      valueListenable: InstallStatusCache.instance.revision,
      builder: (context, _, __) {
        final installed = InstallStatusCache.instance.statusOf(
          path,
          size,
          modifiedMs,
        );
        if (installed == null) return const SizedBox.shrink();

        final l10n = L10n.of(context);
        final theme = Theme.of(context);
        final textScale = 1 + (scale - 1) * 0.3;
        final fontSize = (compact ? 9.0 : 10.0) * textScale;
        final bg = installed
            ? const Color(0xFF2E7D32)
            : theme.colorScheme.surfaceContainerHighest;
        final fg = installed
            ? Colors.white
            : theme.colorScheme.onSurfaceVariant;

        final pill = Container(
          padding: EdgeInsets.symmetric(
            horizontal: (compact ? 4.0 : 5.0) * textScale,
            vertical: 1,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(4),
            border: installed
                ? null
                : Border.all(
                    color: theme.dividerColor.withValues(alpha: 0.5),
                    width: 0.5,
                  ),
          ),
          child: Text(
            installed
                ? l10n.install_status_installed
                : l10n.install_status_not_installed,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: fg,
              fontSize: fontSize,
              height: 1.15,
              fontWeight: FontWeight.w600,
            ),
          ),
        );

        final w = maxWidth;
        if (w == null) return pill;
        return SizedBox(
          width: w,
          child: Center(
            child: FittedBox(fit: BoxFit.scaleDown, child: pill),
          ),
        );
      },
    );
  }
}
