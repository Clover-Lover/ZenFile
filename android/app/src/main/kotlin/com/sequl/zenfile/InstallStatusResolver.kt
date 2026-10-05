package com.sequl.zenfile

import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import java.io.File
import java.util.zip.ZipFile

/**
 * 安装包「已安装 / 未安装」判定（**严格模式**）。
 *
 * 判定口径：**包名 + 版本号 + 架构** 三者同时一致才算「已安装」。
 * 某一维度**任一侧取不到**时 → **跳过该维度**（宁可宽松，也绝不误报「未安装」）。
 *
 * 为什么需要版本 + 架构：`flutter build apk --split-per-abi` 会产出同一包名、
 * 同一 versionName、仅 ABI 不同的多个 APK（arm64-v8a / armeabi-v7a / x86_64）。
 * 只比包名会让这三个文件**全部**显示「已安装」，与用户预期不符。
 * （注：Flutter 的 split-per-abi 还会给各 ABI 的 **versionCode 加偏移**，
 * arm64 / v7a / x86_64 互不相同 —— 这对「架构区分」其实是额外的佐证。）
 *
 * 数据来源（**全部为 android.jar 中编译期可见的公开 API**）：
 *  - 候选文件：`getPackageArchiveInfo` 取包名 / versionName / versionCode；
 *    `lib/<abi>/` 目录名取 ABI。
 *  - 已安装应用：`getInstalledApplications` 取 `ApplicationInfo.nativeLibraryDir`；
 *    版本（name + code）按包名惰性 `getPackageInfo` 并缓存。
 *
 * ⚠️ `ApplicationInfo.primaryCpuAbi` / `secondaryCpuAbi` **是 @hide，不在 android.jar 里，
 * 禁止使用**（用了会在用户构建时报 `Unresolved reference`）。因此架构只能从公开的
 * `nativeLibraryDir` 末段目录名推导，而这只能拿到 ABI **短名**（`arm64` / `arm` /
 * `x86_64` …），候选文件那边拿到的是**全名**（`arm64-v8a` / `armeabi-v7a` …）
 * ⇒ 两边各按自己的写法归一后比较，**两种写法都容忍**（见 [abiMatches]）。
 *
 * 返回码与 Dart 侧 `InstallStatusService` 约定一致：
 * `1` = 已安装、`0` = 未安装、`-1` = 无法判定（Dart 侧不显示标识）。
 */
internal object InstallStatusResolver {

    /** 已安装。 */
    const val INSTALLED = 1

    /** 未安装（包名没对上，或版本 / 架构对不上）。 */
    const val NOT_INSTALLED = 0

    /** 无法判定：文件不存在、扩展名不认识、包名读不出、容器损坏等。 */
    const val UNKNOWN = -1

    /** bundle（.xapk/.apks/.apkm/.aab）内可能出现包名明文的小元数据条目（一律小写比较）。 */
    private val bundleMetaEntries = arrayOf(
        "manifest.json",
        "info.json",
        "meta.json",
        "toc.pb",
        "bundleconfig.pb",
        "base/manifest/androidmanifest.xml",
        "androidmanifest.xml",
    )

    /** 形如 com.example.app 的包名 token。 */
    private val packageTokenRegex =
        Regex("[A-Za-z][A-Za-z0-9_]*(?:\\.[A-Za-z][A-Za-z0-9_]*)+")

    /** 元数据里的版本号键（JSON 形态，如 xapk 的 manifest.json）。 */
    private val metaVersionCodeRegex = Regex("\"version_?code\"\\s*:\\s*\"?(\\d{1,18})\"?")

    /** 元数据里的版本名键（JSON 形态）。 */
    private val metaVersionNameRegex = Regex("\"version_?name\"\\s*:\\s*\"([^\"]{1,64})\"")

    /**
     * 已知 ABI 的**全部常见写法** → 扁平规范名（去掉 `-` / `_` 并小写）。
     *
     * 顺序有讲究：**更具体的写法必须排在前面** —— `x86_64` / `x8664` 要先于 `x86`，
     * `armeabi-v7a` / `armeabiv7a` 要先于 `armeabi`。命中后会把区间掩掉（见 [abisInName]），
     * 所以 `config.x86_64.apk` 不会同时被算成 x86。
     */
    private val abiSpellings: List<Pair<String, String>> = listOf(
        "arm64-v8a" to "arm64v8a",
        "arm64_v8a" to "arm64v8a",
        "arm64v8a" to "arm64v8a",
        "armeabi-v7a" to "armeabiv7a",
        "armeabi_v7a" to "armeabiv7a",
        "armeabiv7a" to "armeabiv7a",
        "x86_64" to "x8664",
        "x8664" to "x8664",
        "riscv64" to "riscv64",
        "mips64" to "mips64",
        "armeabi" to "armeabi",
        "x86" to "x86",
        "mips" to "mips",
    )

    /** 一个版本号（name + code）；任一项取不到就留空 / 0。 */
    private class AppVersion(val name: String, val code: Long) {
        companion object {
            val UNKNOWN = AppVersion("", 0L)
        }
    }

    /**
     * 批量判定。返回 `path -> 状态`。
     *
     * 已安装应用表在一次批量调用内只枚举一次；版本号按包名惰性查询并缓存。
     */
    fun resolveAll(pm: PackageManager, paths: List<String>): HashMap<String, Int> {
        val out = HashMap<String, Int>(paths.size * 2)
        if (paths.isEmpty()) return out

        val installed = HashMap<String, ApplicationInfo>()
        try {
            for (ai in pm.getInstalledApplications(0)) {
                installed[ai.packageName] = ai
            }
        } catch (_: Exception) {
            // 枚举失败（极少见）⇒ 一律「无法判定」，界面不显示标识。
            for (path in paths) out[path] = UNKNOWN
            return out
        }

        val cache = HashMap<String, AppVersion>()
        for (path in paths) {
            out[path] = resolveOne(pm, installed, cache, path)
        }
        return out
    }

    /**
     * 去掉 IM（QQ / 微信 / TIM）追加的序号后缀：`app.xapk.1` → `app.xapk`。
     *
     * 规则与 Dart 侧 `lib/core/im_suffix.dart` 完全一致：末尾 1~4 位纯数字、无前导零、
     * 且点号前已有扩展名才剥（`.001` 分卷 / `README.1` 不动）。
     *
     * ⚠️ 与 `MainActivity.stripImAppendedSuffix` 是同一条规则的**两份实现**
     * （那边是 private，且 `getApkIcon` 在用）。改规则时两处都要改，并同步 Dart 侧。
     */
    fun stripImAppendedSuffix(path: String): String {
        val dot = path.lastIndexOf('.')
        if (dot <= 0 || dot == path.length - 1) return path
        val tail = path.substring(dot + 1)
        if (tail.length > 4) return path
        if (tail[0] == '0') return path
        if (!tail.all { it in '0'..'9' }) return path
        if (!path.substring(0, dot).contains('.')) return path
        return path.substring(0, dot)
    }

    private fun resolveOne(
        pm: PackageManager,
        installed: Map<String, ApplicationInfo>,
        cache: MutableMap<String, AppVersion>,
        path: String,
    ): Int {
        return try {
            if (!File(path).exists()) return UNKNOWN
            val lower = stripImAppendedSuffix(path.lowercase())
            val dot = lower.lastIndexOf('.')
            if (dot < 0) return UNKNOWN
            when (lower.substring(dot + 1)) {
                "apk" -> resolveApk(pm, installed, cache, path)
                "xapk", "apks", "apkm", "aab" -> resolveBundle(pm, installed, cache, path)
                else -> UNKNOWN
            }
        } catch (_: Exception) {
            UNKNOWN
        }
    }

    /** `.apk`：包名 + 版本号 + ABI（后者从 zip 内 `lib/<abi>/` 目录名读）。 */
    private fun resolveApk(
        pm: PackageManager,
        installed: Map<String, ApplicationInfo>,
        cache: MutableMap<String, AppVersion>,
        path: String,
    ): Int {
        val info = archiveInfo(pm, path) ?: return UNKNOWN
        val pkg = info.packageName
        if (pkg.isNullOrEmpty()) return UNKNOWN
        val ai = installed[pkg] ?: return NOT_INSTALLED

        if (!versionMatches(AppVersion(info.versionName.orEmpty(), longVersionCode(info)),
                installedVersion(pm, pkg, cache))) {
            return NOT_INSTALLED
        }
        if (!abiMatches(apkAbis(path), ai.nativeLibraryDir)) return NOT_INSTALLED
        return INSTALLED
    }

    /**
     * `.xapk/.apks/.apkm/.aab`：扫容器内的小元数据条目拿包名，再看容器里能识别的 ABI / 版本。
     *
     * 元数据扫描不必解压出 `base.apk`（对几百 MB 的 xapk 尤其重要）。
     * ABI 线索来自 split 文件名（`config.arm64_v8a.apk` / `base-arm64-v8a.apk`）或
     * `.aab` 的 `base/lib/<abi>/` 路径；两者都取不到就跳过 ABI 检查。
     */
    private fun resolveBundle(
        pm: PackageManager,
        installed: Map<String, ApplicationInfo>,
        cache: MutableMap<String, AppVersion>,
        path: String,
    ): Int {
        if (installed.isEmpty()) return UNKNOWN
        return try {
            ZipFile(path).use { zip ->
                var readAny = false
                var matchedPkg: String? = null
                var metaName = ""
                var metaCode = 0L
                val fileAbis = LinkedHashSet<String>()

                val entries = zip.entries()
                while (entries.hasMoreElements()) {
                    val entry = entries.nextElement()
                    val lowerName = entry.name.lowercase()

                    // ABI 线索：不论是不是元数据条目都先收集（split 文件名 / aab 的 lib 路径）。
                    collectBundleAbi(lowerName, fileAbis)

                    if (lowerName !in bundleMetaEntries) continue
                    if (entry.size > 4L * 1024 * 1024) continue
                    readAny = true
                    // ISO-8859-1 是字节的 1:1 映射，ASCII 包名 token 原样保留，不会因编码丢失。
                    val text = zip.getInputStream(entry).use {
                        it.readBytes().toString(Charsets.ISO_8859_1)
                    }
                    if (matchedPkg == null) {
                        for (m in packageTokenRegex.findAll(text)) {
                            if (installed.containsKey(m.value)) {
                                matchedPkg = m.value
                                break
                            }
                        }
                    }
                    if (metaCode <= 0L) {
                        metaCode = metaVersionCodeRegex.find(text)
                            ?.groupValues?.get(1)?.toLongOrNull() ?: 0L
                    }
                    if (metaName.isEmpty()) {
                        metaName = metaVersionNameRegex.find(text)
                            ?.groupValues?.get(1).orEmpty()
                    }
                }

                val pkg = matchedPkg ?: return if (readAny) NOT_INSTALLED else UNKNOWN
                val ai = installed[pkg] ?: return UNKNOWN

                // 版本：容器元数据里有就比，没有就跳过（.apks/.apkm 的 toc.pb 是 protobuf，
                // 拿不到明文键名 —— 属已知限制，此时退化成「包名 + 架构」判定）。
                if (!versionMatches(AppVersion(metaName, metaCode),
                        installedVersion(pm, pkg, cache))) {
                    return NOT_INSTALLED
                }
                if (!abiMatches(fileAbis, ai.nativeLibraryDir)) return NOT_INSTALLED
                INSTALLED
            }
        } catch (_: Exception) {
            UNKNOWN
        }
    }

    // ---------------------------------------------------------------- 版本号

    /**
     * 版本号比较（严格）：`versionName` 与 `versionCode` 只要**两侧都能取到**就都要相等。
     *
     * 任一侧取不到（name 为空 / code <= 0）→ 跳过该项，避免把「读不出来」误判成「版本不同」。
     */
    private fun versionMatches(file: AppVersion, app: AppVersion): Boolean {
        val fn = file.name.trim()
        val an = app.name.trim()
        if (fn.isNotEmpty() && an.isNotEmpty() && fn != an) return false
        if (file.code > 0L && app.code > 0L && file.code != app.code) return false
        return true
    }

    private fun archiveInfo(pm: PackageManager, path: String): PackageInfo? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.getPackageArchiveInfo(path, PackageManager.PackageInfoFlags.of(0))
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageArchiveInfo(path, 0)
        }

    private fun longVersionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION")
            info.versionCode.toLong()
        }

    /** 已安装应用的版本（按包名缓存；读不到记 [AppVersion.UNKNOWN]）。 */
    private fun installedVersion(
        pm: PackageManager,
        pkg: String,
        cache: MutableMap<String, AppVersion>,
    ): AppVersion {
        cache[pkg]?.let { return it }
        val v = try {
            val pi = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                pm.getPackageInfo(pkg, PackageManager.PackageInfoFlags.of(0))
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(pkg, 0)
            }
            @Suppress("DEPRECATION")
            AppVersion(pi.versionName.orEmpty(), longVersionCode(pi))
        } catch (_: Exception) {
            AppVersion.UNKNOWN
        }
        cache[pkg] = v
        return v
    }

    // ---------------------------------------------------------------- 架构

    /**
     * ABI 比较。**任一侧取不到就跳过**（返回 true）：
     *  - `fileAbis` 为空 ⇒ 该包没有 native 库（如纯 Java 的 APK），不存在 ABI 分包问题；
     *  - `libDir` 为空 / 认不出来 ⇒ 已安装应用没有 native 库。
     *
     * 「认不出来」的兜底很关键：`nativeLibraryDir` 的末段目录名**不是**我们可控的
     * 稳定契约（常见 `arm64` / `arm` / `x86` / `x86_64`，但系统应用可能是 `lib64` 之类），
     * 所以**两种命名约定都容忍**，实在认不出就放弃这一维度而不是报「未安装」。
     */
    private fun abiMatches(fileAbis: Set<String>, libDir: String?): Boolean {
        if (fileAbis.isEmpty()) return true
        val seg = lastPathSegment(libDir) ?: return true
        // ① 目录名本身就是 ABI 全名（arm64-v8a / armeabi-v7a / x86_64 …）
        val byFullName = abisInName(seg)
        if (byFullName.isNotEmpty()) {
            for (f in byFullName) if (fileAbis.contains(f)) return true
            return false
        }
        // ② 目录名是 ABI 短名（arm64 / arm / x86_64 …）
        val byShortName = flatsOfShortAbi(seg)
        if (byShortName.isNotEmpty()) {
            for (f in byShortName) if (fileAbis.contains(f)) return true
            return false
        }
        // ③ 认不出来 ⇒ 跳过 ABI 检查
        return true
    }

    /** 取路径末段并小写（`/data/app/.../lib/arm64` → `arm64`）。 */
    private fun lastPathSegment(path: String?): String? {
        if (path.isNullOrEmpty()) return null
        val s = path.trimEnd('/')
        if (s.isEmpty()) return null
        val idx = s.lastIndexOf('/')
        val seg = (if (idx >= 0) s.substring(idx + 1) else s).lowercase()
        return seg.ifEmpty { null }
    }

    /** ABI **短名**（`nativeLibraryDir` 末段）→ 可接受的扁平全名集合。认不出返回空集。 */
    private fun flatsOfShortAbi(seg: String): Set<String> = when (seg) {
        "arm64" -> setOf("arm64v8a")
        "arm" -> setOf("armeabiv7a", "armeabi")
        "x86_64", "x8664" -> setOf("x8664")
        "x86" -> setOf("x86")
        "riscv64" -> setOf("riscv64")
        "mips64" -> setOf("mips64")
        "mips" -> setOf("mips")
        else -> emptySet()
    }

    /** 读一个 APK 的 zip 内 `lib/<abi>/` 目录名，返回扁平规范名集合。 */
    private fun apkAbis(path: String): Set<String> {
        val out = LinkedHashSet<String>()
        try {
            ZipFile(path).use { zip ->
                val entries = zip.entries()
                var guard = 0
                while (entries.hasMoreElements() && guard < 200_000) {
                    guard++
                    val name = entries.nextElement().name.lowercase()
                    if (!name.startsWith("lib/")) continue
                    val rest = name.substring(4)
                    val slash = rest.indexOf('/')
                    if (slash <= 0) continue
                    out.addAll(abisInName(rest.substring(0, slash)))
                }
            }
        } catch (_: Exception) {
            // 读不了 zip（损坏 / 无权限）⇒ 空集 ⇒ 上层跳过 ABI 检查。
        }
        return out
    }

    /** 从容器条目名里收集 ABI：`lib/<abi>/` 路径、以及 `config.<abi>.apk` 之类的 split 文件名。 */
    private fun collectBundleAbi(lowerName: String, out: MutableSet<String>) {
        val segs = lowerName.split('/')
        // ① `lib/<abi>/...`（.aab 与解包后的 APK）
        for (i in 0 until segs.size - 1) {
            if (segs[i] == "lib") out.addAll(abisInName(segs[i + 1]))
        }
        // ② split 文件名（config.arm64_v8a.apk / base-arm64-v8a.apk / …）
        val file = segs[segs.size - 1]
        if (!file.endsWith(".apk")) return
        out.addAll(abisInName(file.substring(0, file.length - 4)))
    }

    /**
     * 在一个名字里找 ABI token，返回**扁平规范名**集合。
     *
     * 两条约束保证不误判：
     *  1. **边界**要求 —— token 两侧必须是串首 / 串尾或 `.` `_` `-` 空格，
     *     所以 `x86tools` 不会命中 x86；
     *  2. **命中即掩** —— 命中的区间换成 `#`（非边界字符），
     *     所以 `x86_64` 命中后，里面的 `x86` 不会再被算一次。
     */
    private fun abisInName(name: String): Set<String> {
        if (name.isEmpty()) return emptySet()
        var s = name.lowercase()
        val found = LinkedHashSet<String>()
        for ((spelling, flat) in abiSpellings) {
            var from = 0
            while (true) {
                val at = s.indexOf(spelling, from)
                if (at < 0) break
                val end = at + spelling.length
                if (isAbiBoundary(s, at - 1) && isAbiBoundary(s, end)) {
                    found.add(flat)
                    s = s.substring(0, at) + "#".repeat(spelling.length) + s.substring(end)
                    break
                }
                from = at + 1
            }
        }
        return found
    }

    private fun isAbiBoundary(s: String, index: Int): Boolean {
        if (index < 0 || index >= s.length) return true
        return when (s[index]) {
            '.', '_', '-', ' ' -> true
            else -> false
        }
    }
}
