package com.sequl.zenfile

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.widget.Toast
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 系统文件选择器桥接：让第三方 App（QQ / 微信等）用 ACTION_GET_CONTENT 选文件时，
 * 直接使用 ZenFile **自己的**文件浏览器，而不是系统选择器里由 DocumentsUI 渲染的
 * 简陋「ZenFile Storage」列表页。
 *
 * 流程：
 * 1. 第三方 App 发起 ACTION_GET_CONTENT → 系统 chooser 里出现 ZenFile → 启动 MainActivity；
 * 2. Activity.onCreate 之前调用 [onLaunchIntent] 记下本次是「选文件」启动；
 * 3. Dart 侧查询 getPickerInfo 后打开 InternalFilePickerScreen 让用户选；
 * 4. Dart 调 finishPick(paths) → 这里把路径转成 ZenFileDocumentsProvider 的
 *    document URI 回传给调起方，并结束本页。
 *
 * 之所以把逻辑放在独立文件：MainActivity.kt 是 3000+ 行的大文件且 classpath 凑不齐，
 * 只能做语法检查；独立文件可被 scripts/check_kotlin.py **真编译**，能提前打掉
 * API 不存在 / 参数个数不符这类「只在用户真机构建时才炸」的错误。
 */
class SystemFilePickerBridge(private val activity: Activity) {

    /** 本次是否由第三方 App 以「选文件」为目的调起。 */
    var isPickerLaunch = false
        private set

    /** 调起方是否允许多选（Intent.EXTRA_ALLOW_MULTIPLE）。 */
    var allowMultiple = false
        private set

    /** 调起方要求的 MIME 类型（可能是通配类型或 null，即不限制）。 */
    var mimeType: String? = null
        private set

    /**
     * 读取启动 intent，判定是否为系统文件选择器模式。
     * 必须在 Activity 的 super.onCreate() **之前**调用 —— Dart 侧启动后会异步查询本状态。
     */
    fun onLaunchIntent(intent: Intent?) {
        val action = intent?.action
        if (action == Intent.ACTION_GET_CONTENT || action == Intent.ACTION_PICK) {
            isPickerLaunch = true
            allowMultiple = intent?.getBooleanExtra(Intent.EXTRA_ALLOW_MULTIPLE, false) ?: false
            mimeType = intent?.type
        }
    }

    /** 注册供 Dart 侧调用的通道。 */
    fun registerChannel(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getPickerInfo" -> {
                    result.success(
                        mapOf(
                            "isPicker" to isPickerLaunch,
                            "allowMultiple" to allowMultiple,
                            "mime" to mimeType
                        )
                    )
                }
                "finishPick" -> {
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    result.success(deliverPickedFiles(paths))
                }
                "cancelPick" -> {
                    activity.setResult(Activity.RESULT_CANCELED)
                    activity.finish()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * 把 Dart 侧选中的文件路径转成 ZenFileDocumentsProvider 的 document URI 回传给调起方。
     * 仅支持 /storage/emulated/0 下的路径 —— 与 provider 暴露的 root 保持一致。
     * @return 是否成功回传；false 表示没有任何可用 URI（已按「取消」处理）。
     */
    private fun deliverPickedFiles(paths: List<String>): Boolean {
        val limited = if (allowMultiple) paths else paths.take(1)
        val uris = limited.mapNotNull { path -> buildDocumentUriForPath(path) }
        if (uris.isEmpty()) {
            // 选中的文件不在 provider 暴露的内部存储 root 下，无法回传可读取的 URI。
            Toast.makeText(activity, R.string.picker_only_internal_storage, Toast.LENGTH_LONG).show()
            activity.setResult(Activity.RESULT_CANCELED)
            activity.finish()
            return false
        }
        val data = Intent()
        if (uris.size == 1) {
            data.data = uris[0]
        } else {
            // 多选：ClipData 承载全部 URI，同时保留 data 指向第一个
            // （兼容只读 Intent.data 的老调用方）。
            val clip = ClipData.newUri(activity.contentResolver, "ZenFile", uris[0])
            for (i in 1 until uris.size) {
                clip.addItem(ClipData.Item(uris[i]))
            }
            data.clipData = clip
            data.data = uris[0]
        }
        data.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        activity.setResult(Activity.RESULT_OK, data)
        activity.finish()
        return true
    }

    /**
     * 文件路径 → ZenFileDocumentsProvider 的 document URI。
     * docId 规则与 ZenFileDocumentsProvider.getDocIdForFile() 严格一致（rootId = "primary"）。
     */
    private fun buildDocumentUriForPath(path: String): Uri? {
        val abs = File(path).absolutePath
        if (!abs.startsWith(ROOT)) return null
        var rel = abs.substring(ROOT.length)
        if (rel.startsWith("/")) rel = rel.substring(1)
        if (rel.isEmpty()) return null
        val authority = "${activity.packageName}$DOCUMENTS_AUTHORITY_SUFFIX"
        return DocumentsContract.buildDocumentUri(authority, "primary:$rel")
    }

    private companion object {
        const val CHANNEL = "com.sequl.zenfile/file_picker"
        const val ROOT = "/storage/emulated/0"
        // 与 AndroidManifest 中 provider 的 android:authorities="${applicationId}.documents" 一致
        const val DOCUMENTS_AUTHORITY_SUFFIX = ".documents"
    }
}
