/// SSH 主机密钥 TOFU 存储回归（accept-new 语义）。
///
/// 此前两条 SFTP 通道均不校验主机密钥（MITM 敞开）。本测试钉住：
///  1. 首次连接记录指纹并放行；
///  2. 指纹一致放行；
///  3. 指纹不一致（服务器重装/被劫持）拒绝；
///  4. 不同主机/端口的记录互不干扰。
import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/ssh_host_key_store.dart';

void main() {
  // 测试用内存存储（生产环境为 FlutterSecureStorage）
  late Map<String, String> store;

  setUp(() {
    store = {};
    SshHostKeyStore.overrideStore = store;
  });

  tearDown(() {
    SshHostKeyStore.overrideStore = null;
  });

  test('首次连接记录指纹并放行', () async {
    final ok = await SshHostKeyStore.verifyTofu(
      host: 'nas.local',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:AAAA',
    );
    expect(ok, isTrue);
    expect(store['sftp_hostkey_nas.local_22'], 'ssh-ed25519 SHA256:AAAA');
  });

  test('指纹一致放行', () async {
    await SshHostKeyStore.verifyTofu(
      host: 'nas.local',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:AAAA',
    );
    final ok = await SshHostKeyStore.verifyTofu(
      host: 'nas.local',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:AAAA',
    );
    expect(ok, isTrue);
  });

  test('指纹不一致（服务器变更/劫持）拒绝', () async {
    await SshHostKeyStore.verifyTofu(
      host: 'nas.local',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:AAAA',
    );
    final ok = await SshHostKeyStore.verifyTofu(
      host: 'nas.local',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:BBBB',
    );
    expect(ok, isFalse);
  });

  test('同算法变更后的指纹不一致也拒绝（跨算法替换）', () async {
    await SshHostKeyStore.verifyTofu(
      host: 'box',
      port: 2222,
      keyType: 'ssh-rsa',
      fingerprint: 'SHA256:CCCC',
    );
    final ok = await SshHostKeyStore.verifyTofu(
      host: 'box',
      port: 2222,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:CCCC',
    );
    expect(ok, isFalse);
  });

  test('不同主机/端口互不干扰', () async {
    expect(
      await SshHostKeyStore.verifyTofu(
        host: 'a',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:K1',
      ),
      isTrue,
    );
    expect(
      await SshHostKeyStore.verifyTofu(
        host: 'b',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:K2',
      ),
      isTrue,
    );
    expect(
      await SshHostKeyStore.verifyTofu(
        host: 'a',
        port: 2222,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:K3',
      ),
      isTrue,
    );
    expect(
      await SshHostKeyStore.verifyTofu(
        host: 'a',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:K1',
      ),
      isTrue,
    );
  });

  test('sha256Fingerprint 与 OpenSSH 格式一致（无 padding）', () {
    final fp = SshHostKeyStore.sha256Fingerprint([1, 2, 3]);
    expect(fp.startsWith('SHA256:'), isTrue);
    expect(fp.contains('='), isFalse, reason: 'OpenSSH 指纹不含 padding');
  });
}
