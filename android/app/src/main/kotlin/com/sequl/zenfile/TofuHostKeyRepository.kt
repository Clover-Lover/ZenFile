package com.sequl.zenfile

import android.util.Base64
import com.jcraft.jsch.HostKey
import com.jcraft.jsch.HostKeyRepository
import com.jcraft.jsch.UserInfo
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean

/**
 * SSH 主机密钥 TOFU（Trust On First Use）仓库 —— ZenFile 本地补丁（2026-10-02）。
 *
 * 此前原生通道写死 `StrictHostKeyChecking=no`，对中间人攻击（MITM）完全敞开。
 * 本仓库实现 accept-new 语义：
 *  - 首次连接：记录 (主机, 算法, 公钥) 并信任，返回 [HostKeyRepository.OK]；
 *  - 后续连接：算法+公钥一致 → 放行（OK）；
 *  - 不一致（服务器重装 / 被劫持）→ 拒绝（CHANGED，JSch 会抛异常终止连接）。
 *
 * ⚠️ mwiede/jsch 2.x 的 HostKeyRepository 是**接口**，且 `check()` 不带
 * port 参数（旧 0.1.55 是抽象类 + `check(host, port, key)`），因此记录
 * 仅按主机名区分；同一主机的非 22 端口会共享指纹条目。
 *
 * known_hosts 文件采用 OpenSSH 兼容的 `host algorithm base64key` 行格式，
 * 存放于应用私有目录（filesDir/sftp_known_hosts），仅本应用可读写。
 */
class TofuHostKeyRepository(private val knownHostsFile: File) : HostKeyRepository {

    private data class Entry(val type: String, val key: String)

    private val entries = LinkedHashMap<String, MutableList<Entry>>()
    private val loaded = AtomicBoolean(false)

    private fun loadIfNeeded() {
        if (!loaded.compareAndSet(false, true)) return
        try {
            if (!knownHostsFile.exists()) return
            knownHostsFile.readLines().forEach { line ->
                val trimmed = line.trim()
                if (trimmed.isEmpty() || trimmed.startsWith("#")) return@forEach
                val parts = trimmed.split(" ")
                if (parts.size < 3) return@forEach
                val host = parts[0]
                val type = parts[1]
                val key = parts.subList(2, parts.size).joinToString(" ")
                entries.getOrPut(host) { mutableListOf() }.add(Entry(type, key))
            }
        } catch (_: Exception) {
            // 读取失败按空仓库处理：下次连接重新记录（安全性退化为首次状态，可接受）
        }
    }

    private fun save() {
        try {
            knownHostsFile.parentFile?.mkdirs()
            knownHostsFile.writeText(entries.flatMap { (host, list) ->
                list.map { "$host ${it.type} ${it.key}" }
            }.joinToString("\n"))
        } catch (_: Exception) {
            // 写入失败时本会话仍持有内存记录，下次启动重新 TOFU
        }
    }

    /** 从 SSH wire-format 公钥 blob 头部解析算法名（[4字节长度][算法名 ASCII]）。 */
    private fun keyTypeOf(pubkey: ByteArray): String {
        if (pubkey.size < 4) return "unknown"
        val len = ((pubkey[0].toInt() and 0xff) shl 24) or
            ((pubkey[1].toInt() and 0xff) shl 16) or
            ((pubkey[2].toInt() and 0xff) shl 8) or
            (pubkey[3].toInt() and 0xff)
        if (len <= 0 || 4 + len > pubkey.size) return "unknown"
        return String(pubkey, 4, len, Charsets.US_ASCII)
    }

    override fun check(host: String, pubkey: ByteArray): Int {
        synchronized(this) {
            loadIfNeeded()
            val keyB64 = Base64.encodeToString(pubkey, Base64.NO_WRAP)
            val type = keyTypeOf(pubkey)
            val known = entries[host]
            if (known == null) {
                entries[host] = mutableListOf(Entry(type, keyB64))
                save()
                return HostKeyRepository.OK
            }
            return if (known.any { it.type == type && it.key == keyB64 }) {
                HostKeyRepository.OK
            } else {
                HostKeyRepository.CHANGED
            }
        }
    }

    override fun add(hostkey: HostKey?, ui: UserInfo?) {
        // TOFU 语义下不通过 add() 记录（check() 内已自动记录）
    }

    override fun remove(host: String?, type: String?) {
        if (host == null) return
        synchronized(this) {
            entries[host]?.removeAll { type == null || it.type == type }
            if (entries[host]?.isEmpty() == true) entries.remove(host)
            save()
        }
    }

    override fun remove(host: String?, type: String?, blob: ByteArray?) {
        remove(host, type)
    }

    override fun getKnownHostsRepositoryID(): String = knownHostsFile.absolutePath

    override fun getHostKey(): Array<HostKey> = getHostKey(null, null)

    override fun getHostKey(host: String?, type: String?): Array<HostKey> = arrayOf()
}
