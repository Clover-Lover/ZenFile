import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../core/icon_fonts/broken_icons.dart';
import '../../models/network_connection_model.dart';
import '../../services/network_connections_service.dart';
import '../../services/netdisk_auth_store.dart';
import '../../providers/file_manager_provider.dart';
import '../../services/remote_guard_service.dart';
import 'package:zenfile/l10n/generated/app_localizations.dart';

import 'network_connection_wizard_screen.dart';

class NetworkCategoryScreen extends StatefulWidget {
  final Function(int)? onNavigateTab;

  const NetworkCategoryScreen({super.key, this.onNavigateTab});

  @override
  State<NetworkCategoryScreen> createState() => _NetworkCategoryScreenState();
}

class _NetworkCategoryScreenState extends State<NetworkCategoryScreen> {
  List<NetworkConnectionModel> _connections = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadConnections();
  }

  void _loadConnections() {
    setState(() {
      // 聚合网盘连接（NETDISK_*）与远程协议连接统一在此展示，
      // 添加网盘入口位于添加向导（NetworkConnectionWizardScreen）分割线下方
      _connections = NetworkConnectionsService.getConnections().toList();
      _isLoading = false;
    });
  }

  bool _isNetdisk(NetworkConnectionModel c) =>
      c.type.toLowerCase().contains('netdisk');

  IconData _getIconForType(String type) {
    if (FileManagerProvider.isSmbType(type)) return Icons.dns_rounded;
    if (type.toLowerCase().contains('quark')) return Broken.cloud;
    if (type.toLowerCase().contains('netdisk')) return Icons.cloud_rounded;
    switch (type) {
      case 'FTP':
        return Icons.swap_horizontal_circle_rounded;
      case 'SFTP':
        return Icons.vpn_lock_rounded;
      case 'WebDav':
        return Icons.web_rounded;
      default:
        return Broken.wifi;
    }
  }

  Color _getColorForType(String type) {
    if (FileManagerProvider.isSmbType(type)) return const Color(0xFF5B21B6);
    if (type.toLowerCase().contains('quark')) return const Color(0xFF2B6CB0);
    if (type.toLowerCase().contains('netdisk')) return const Color(0xFFFF6A00);
    switch (type) {
      case 'FTP':
        return const Color(0xFFF97316);
      case 'SFTP':
        return const Color(0xFF0D9488);
      case 'WebDav':
        return const Color(0xFFE11D48);
      default:
        return const Color(0xFF00BCD4);
    }
  }

  Future<void> _deleteConnection(NetworkConnectionModel conn) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(L10n.of(context).msg432fbb31, style: TextStyle(fontWeight: FontWeight.bold)),
        content: Text(L10n.of(context).msgdeleteconn(conn.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(L10n.of(context).ui_cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            child: Text(L10n.of(context).ui_delete),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await NetworkConnectionsService.deleteConnection(conn.id);
      // 网盘连接删除即退出登录：同步清除加密存储的登录态
      if (conn.type.toLowerCase().contains('netdisk')) {
        await NetdiskAuthStore.clearAuth(conn.id);
      }
      _loadConnections();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Broken.arrow_left),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          L10n.of(context).ui_network,
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Broken.add),
            tooltip: L10n.of(context).msg3358aa10,
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => NetworkConnectionWizardScreen(onNavigateTab: widget.onNavigateTab)),
              );
              _loadConnections();
            },
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _connections.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Broken.wifi, size: 64, color: theme.colorScheme.onSurface.withOpacity(0.15)),
                      const SizedBox(height: 20),
                      Text(
                        L10n.of(context).msgc9c900d0,
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onSurface.withOpacity(0.5),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        L10n.of(context).ftpsftpwebdavsmb1,
                        style: TextStyle(
                          color: theme.colorScheme.onSurface.withOpacity(0.4),
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 24),
                      ElevatedButton.icon(
                        onPressed: () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => NetworkConnectionWizardScreen(onNavigateTab: widget.onNavigateTab)),
                          );
                          _loadConnections();
                        },
                        icon: const Icon(Broken.add),
                        label: Text(L10n.of(context).msg3358aa10),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
                  itemCount: _connections.length,
                  itemBuilder: (context, index) {
                    final conn = _connections[index];
                    final color = _getColorForType(conn.type);
                    final iconData = _getIconForType(conn.type);

                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      color: isDark ? const Color(0xFF1E1E2A) : Colors.white,
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        leading: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: color.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(iconData, color: color, size: 24),
                        ),
                        title: Text(
                          conn.name,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          // 网盘连接无 host/port，副标题显示登录状态；
                          // 协议连接显示类型与 host:port 两行（垂直方向有空间，两行都能完整展示）
                          child: _isNetdisk(conn)
                              ? Text(
                                  L10n.of(context).netdisk_logged_in,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                                  ),
                                )
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      conn.type,
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: theme.colorScheme.onSurface.withOpacity(0.5),
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${conn.host}:${conn.port}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: theme.colorScheme.onSurface.withOpacity(0.5),
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 网盘连接无协议参数可编辑，仅保留删除（退出登录）
                            if (!_isNetdisk(conn))
                              IconButton(
                                icon: Icon(Broken.edit, size: 18, color: theme.colorScheme.primary),
                                onPressed: () async {
                                  // 编辑页可见密码，远程保护开启且未解锁时先验证 PIN
                                  if (!await RemoteGuardService.guard(context)) return;
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => NetworkConnectionWizardScreen(existingConnection: conn),
                                    ),
                                  );
                                  _loadConnections();
                                },
                              ),
                            IconButton(
                              icon: const Icon(Broken.trash, size: 18, color: Colors.red),
                              onPressed: () => _deleteConnection(conn),
                            ),
                          ],
                        ),
                        onTap: () async {
                          final provider = context.read<FileManagerProvider>();
                          // 远程保护开启且未解锁时，先验证 PIN 再连接
                          if (!await RemoteGuardService.guard(context)) return;
                          final client = FileManagerProvider.createRemoteClient(conn);
                          try {
                            await client.connect();
                            if (context.mounted) {
                              provider.openRemoteTab(client, conn);
                              // 通知首页切换到浏览页，并关闭当前页面
                              widget.onNavigateTab?.call(1);
                              Navigator.pop(context);
                            }
                          } catch (e) {
                            if (context.mounted) {
                              final l10n = L10n.of(context);
                              // 网盘登录态过期：显示本地化提示并清理该连接
                              final expired = e.toString() == 'netdisk_auth_expired';
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(expired
                                      ? l10n.netdisk_auth_expired
                                      : l10n.e13(e.toString())),
                                  backgroundColor: Colors.redAccent,
                                ),
                              );
                              if (expired) {
                                await NetworkConnectionsService.deleteConnection(conn.id);
                                await NetdiskAuthStore.clearAuth(conn.id);
                                _loadConnections();
                              }
                            }
                          }
                        },
                      ),
                    );
                  },
                ),
    );
  }
}
