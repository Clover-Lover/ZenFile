import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zenfile/services/backup_secrets_codec.dart';

void main() {
  test('encrypt -> decrypt roundtrip', () async {
    const payload = <String, dynamic>{
      'prefs': {'vault_salt': 'abc', 'ftp_password': 'p@ss w0rd\'"x'},
      'connection_credentials': <String, dynamic>{
        'conn1': {'password': 'secret1', 'sshKeyPassword': ''},
      },
      'mount_passwords': <String, dynamic>{'/storage/emulated/0/box': 'pw2'},
      'crypt_profiles': '[]',
    };

    final block = await BackupSecretsCodec.encrypt(payload, '口令123!');
    expect(block['scheme'], BackupSecretsCodec.scheme);
    expect(block['ciphertext'], isNot(contains('secret1')));

    // 明文负载绝不能出现在密文块的 JSON 里
    final blockJson = jsonEncode(block);
    expect(blockJson.contains('secret1'), isFalse);
    expect(blockJson.contains('pw2'), isFalse);

    final restored = await BackupSecretsCodec.decrypt(block, '口令123!');
    expect(restored['prefs']['vault_salt'], 'abc');
    expect(
      restored['connection_credentials']['conn1']['password'],
      'secret1',
    );
    expect(restored['mount_passwords']['/storage/emulated/0/box'], 'pw2');
  });

  test('wrong passphrase throws BackupPassphraseException', () async {
    final block = await BackupSecretsCodec.encrypt(
      <String, dynamic>{'prefs': <String, dynamic>{}},
      'right-pass',
    );
    expect(
      () => BackupSecretsCodec.decrypt(block, 'wrong-pass'),
      throwsA(isA<BackupPassphraseException>()),
    );
  });

  test('wrong scheme throws FormatException', () async {
    expect(
      () => BackupSecretsCodec.decrypt(
        <String, dynamic>{'scheme': 'other'},
        'x',
      ),
      throwsA(isA<FormatException>()),
    );
  });
}
