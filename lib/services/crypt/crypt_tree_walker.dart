/// 加密目录树的遍历工具。
///
/// 刻意做成**纯 Dart**（只依赖 `dart:io`）：`CryptOperations` 传递依赖
/// `flutter_secure_storage`，在本机无法脱离 Flutter 运行；而「目录改名顺序」
/// 是加/解密里最容易写错、错了就毁数据的一环，独立成模块后可以直接用原生
/// VM 跑回归（见 `.local/verify_tree_walker.dart` 与
/// `test/crypt/crypt_parallel_batch_test.dart`）。
library;

import 'dart:io';

/// 目录树遍历工具集。
class CryptTreeWalker {
  CryptTreeWalker._();

  /// 递归列出 [dirPath] 下的**所有文件**路径（目录不存在时返回空表）。
  ///
  /// 元素顺序不保证，调用方不要依赖。
  static Future<List<String>> listFilesRecursive(String dirPath) async {
    final files = <String>[];
    final dir = Directory(dirPath);
    if (!await dir.exists()) return files;

    final entities = await dir.list(recursive: true).toList();
    for (final entity in entities) {
      if (entity is File) files.add(entity.path);
    }
    return files;
  }

  /// 收集 [dirPath] 下的全部**子目录**，按「后序」排列 = **最深的最先**。
  ///
  /// ## 为什么必须是这个顺序
  ///
  /// 原地加密/解密要连目录名一起改。改名一个子目录**不会**影响它父目录的路径，
  /// 反过来则会让「已经收集好的深层路径」全部失效。所以必须从最深处往浅处改；
  /// 原实现靠递归天然满足，改成「先并行处理文件、再统一改目录名」的两阶段后，
  /// 必须显式保证同一顺序。
  ///
  /// **不包含** [dirPath] 自身 —— 顶层目录名由调用方单独处理（挂载点根目录
  /// 有特殊语义，改名会让 `containsPath` 失配，导致重启后解密层找不到挂载点）。
  static Future<List<String>> listSubDirsDeepestFirst(String dirPath) async {
    final out = <String>[];
    await _collectPostOrder(Directory(dirPath), out);
    return out;
  }

  /// 后序遍历：先递归子树，再把自己追加进 [out]。
  static Future<void> _collectPostOrder(Directory dir, List<String> out) async {
    final entities = await dir.list().toList();
    for (final entity in entities) {
      if (entity is! Directory) continue;
      await _collectPostOrder(entity, out);
      out.add(entity.path);
    }
  }
}
