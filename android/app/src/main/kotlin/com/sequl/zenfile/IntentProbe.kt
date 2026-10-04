package com.sequl.zenfile

import android.content.Intent
import android.os.Environment
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * ⚠️ 临时取证代码（排查「第三方 App 选文件时调不起 ZenFile 自家界面」用）。
 *
 * 现状：vivo 的「打开文档」抽屉里 ZenFile Storage 条目右侧有「↪（用应用打开）」，
 * 但点它是否能调起 ZenFile、调起时系统发了什么 intent，全无线索（无 adb）。
 * 本对象把每一个到达 MainActivity 的启动 intent 追加写入
 *   /storage/emulated/0/ZenFile/intent_probe.log
 * 用户复现一次后取回日志即可定位：
 *   - 日志里**完全没有**对应记录 ⇒ 系统根本没把 intent 发到 ZenFile（filter/候选问题）；
 *   - 有记录但 action 不是 GET_CONTENT/OPEN_DOCUMENT/PICK ⇒ vivo 发的是别的 action；
 *   - action 正确 ⇒ 问题在 Dart 侧判定/界面切换。
 *
 * 排查结束后删除本文件与 MainActivity 中的两处 IntentProbe.record 调用。
 */
object IntentProbe {
    private const val DIR_NAME = "ZenFile"
    private const val FILE_NAME = "intent_probe.log"

    fun record(tag: String, intent: Intent?) {
        append(
            tag,
            StringBuilder()
                .append("action=").append(intent?.action)
                .append(" comp=").append(intent?.component?.flattenToShortString())
                .append(" type=").append(intent?.type)
                .append(" cat=").append(intent?.categories?.joinToString(","))
                .append(" data=").append(intent?.dataString)
                .append(" flags=0x").append(Integer.toHexString(intent?.flags ?: 0))
                .append(" extras=").append(intent?.extras?.keySet()?.joinToString(","))
                .toString()
        )
    }

    /** 记录一行纯文本备注（如「推送时 channel 是否为 null」）。 */
    fun note(tag: String, text: String) {
        append(tag, text)
    }

    private fun append(tag: String, body: String) {
        try {
            val dir = File(Environment.getExternalStorageDirectory(), DIR_NAME)
            if (!dir.exists() && !dir.mkdirs()) return
            val line = StringBuilder()
                .append(SimpleDateFormat("MM-dd HH:mm:ss.SSS", Locale.US).format(Date()))
                .append(" [").append(tag).append("] ")
                .append(body)
                .append('\n')
                .toString()
            File(dir, FILE_NAME).appendText(line)
        } catch (_: Throwable) {
            // 取证失败不影响主流程
        }
    }
}
