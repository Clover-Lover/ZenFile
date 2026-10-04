package com.sequl.zenfile

import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Point
import android.media.MediaMetadataRetriever
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsProvider
import android.webkit.MimeTypeMap
import java.io.File
import java.io.FileNotFoundException
import java.io.FileOutputStream
import java.security.MessageDigest

class ZenFileDocumentsProvider : DocumentsProvider() {

    private val DEFAULT_ROOT_PROJECTION = arrayOf(
        DocumentsContract.Root.COLUMN_ROOT_ID,
        DocumentsContract.Root.COLUMN_MIME_TYPES,
        DocumentsContract.Root.COLUMN_FLAGS,
        DocumentsContract.Root.COLUMN_ICON,
        DocumentsContract.Root.COLUMN_TITLE,
        DocumentsContract.Root.COLUMN_SUMMARY,
        DocumentsContract.Root.COLUMN_DOCUMENT_ID,
        DocumentsContract.Root.COLUMN_AVAILABLE_BYTES
    )

    private val DEFAULT_DOCUMENT_PROJECTION = arrayOf(
        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
        DocumentsContract.Document.COLUMN_MIME_TYPE,
        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
        DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        DocumentsContract.Document.COLUMN_FLAGS,
        DocumentsContract.Document.COLUMN_SIZE
    )

    override fun onCreate(): Boolean {
        return true
    }

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val flags = DocumentsContract.Root.FLAG_LOCAL_ONLY or 
                    DocumentsContract.Root.FLAG_SUPPORTS_CREATE or 
                    DocumentsContract.Root.FLAG_SUPPORTS_IS_CHILD

        val result = MatrixCursor(projection ?: DEFAULT_ROOT_PROJECTION)
        val row = result.newRow()
        row.add(DocumentsContract.Root.COLUMN_ROOT_ID, "primary")
        row.add(DocumentsContract.Root.COLUMN_DOCUMENT_ID, getDocIdForFile(File("/storage/emulated/0")))
        row.add(DocumentsContract.Root.COLUMN_MIME_TYPES, "*/*")
        row.add(DocumentsContract.Root.COLUMN_FLAGS, flags)
        row.add(DocumentsContract.Root.COLUMN_TITLE, "ZenFile Storage")
        // 副标题同时兼作引导语：抽屉里点条目本体进的是 DocumentsUI 渲染的列表，
        // 点右侧「↪（用应用打开）」才进 ZenFile 自家选择器，用一句提示降低误点。
        row.add(
            DocumentsContract.Root.COLUMN_SUMMARY,
            context?.getString(R.string.picker_root_summary) ?: "Internal storage"
        )
        row.add(DocumentsContract.Root.COLUMN_ICON, android.R.drawable.sym_def_app_icon)
        
        try {
            val stat = android.os.StatFs("/storage/emulated/0")
            val availableBytes = stat.availableBlocksLong * stat.blockSizeLong
            row.add(DocumentsContract.Root.COLUMN_AVAILABLE_BYTES, availableBytes)
        } catch (e: Exception) {
            row.add(DocumentsContract.Root.COLUMN_AVAILABLE_BYTES, 0L)
        }

        return result
    }

    override fun queryDocument(documentId: String?, projection: Array<out String>?): Cursor {
        val result = MatrixCursor(projection ?: DEFAULT_DOCUMENT_PROJECTION)
        val file = getFileForDocId(documentId ?: "primary:")
        includeFile(result, documentId, file)
        return result
    }

    override fun queryChildDocuments(
        parentDocumentId: String?,
        projection: Array<out String>?,
        sortOrder: String?
    ): Cursor {
        val result = MatrixCursor(projection ?: DEFAULT_DOCUMENT_PROJECTION)
        val parent = getFileForDocId(parentDocumentId ?: "primary:")
        parent.listFiles()?.forEach { file ->
            val childId = getDocIdForFile(file)
            includeFile(result, childId, file)
        }
        return result
    }

    override fun openDocument(
        documentId: String?,
        mode: String?,
        signal: CancellationSignal?
    ): ParcelFileDescriptor {
        val file = getFileForDocId(documentId ?: "")
        val accessMode = ParcelFileDescriptor.parseMode(mode ?: "r")
        return ParcelFileDescriptor.open(file, accessMode)
    }

    // ===== 缩略图：让 DocumentsUI 渲染的「打开文档」列表显示图片/视频缩略图 =====
    // 做法与 AOSP FileSystemProvider 一致：解码 → 写 provider 私有缓存 → 返回只读 fd。
    // 不支持的类型直接抛 FileNotFoundException，DocumentsUI 会回退到通用 MIME 图标。

    override fun openDocumentThumbnail(
        documentId: String,
        sizeHint: Point,
        signal: CancellationSignal?
    ): AssetFileDescriptor {
        val file = getFileForDocId(documentId)
        if (!file.isFile) throw FileNotFoundException("No thumbnail for $documentId")

        val mime = getMimeType(file)
        val bitmap = when {
            mime.startsWith("image/") -> decodeImageThumbnail(file, signal)
            mime.startsWith("video/") -> decodeVideoThumbnail(file, signal)
            else -> null
        } ?: throw FileNotFoundException("Thumbnail not available for $documentId")

        val out = thumbnailCacheFile(documentId)
        // 先写临时文件再原子改名：并发请求同一 docId 时不会读到写了一半的文件。
        val tmp = File(out.parentFile, ".tmp-" + out.name)
        try {
            FileOutputStream(tmp).use { fos -> bitmap.compress(Bitmap.CompressFormat.JPEG, 85, fos) }
            if (!tmp.renameTo(out)) {
                out.delete()
                if (!tmp.renameTo(out)) throw FileNotFoundException("Failed to write thumbnail")
            }
        } finally {
            tmp.delete()
            bitmap.recycle()
        }
        return AssetFileDescriptor(
            ParcelFileDescriptor.open(out, ParcelFileDescriptor.MODE_READ_ONLY),
            0,
            out.length()
        )
    }

    /** 图片缩略图：按尺寸算 inSampleSize 后整图解码，避免大图 OOM。 */
    private fun decodeImageThumbnail(file: File, signal: CancellationSignal?): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeFile(file.absolutePath, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null

        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / (sample * 2) >= THUMB_MAX_DIMENSION) {
            sample *= 2
        }
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        signal?.throwIfCanceled()
        return BitmapFactory.decodeFile(file.absolutePath, opts)
    }

    /** 视频缩略图：取关键帧。失败返回 null，由调用方回退到通用图标。 */
    private fun decodeVideoThumbnail(file: File, signal: CancellationSignal?): Bitmap? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(file.absolutePath)
            signal?.throwIfCanceled()
            retriever.getFrameAtTime(
                0,
                MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            )
        } catch (e: Exception) {
            null
        } finally {
            try {
                retriever.release()
            } catch (e: Exception) {
                // release 失败不影响结果
            }
        }
    }

    /**
     * 缩略图缓存文件：cacheDir/saf_thumbs/<md5(documentId)>.jpg。
     * 超过上限整目录清空即可（缩略图随时可重建，不需要精确的 LRU）。
     */
    private fun thumbnailCacheFile(documentId: String): File {
        val dir = File(context!!.cacheDir, "saf_thumbs")
        if (!dir.exists()) dir.mkdirs()
        val existing = dir.listFiles()
        if (existing != null && existing.size > THUMB_CACHE_MAX_FILES) {
            existing.forEach { it.delete() }
        }
        val digest = MessageDigest.getInstance("MD5")
            .digest(documentId.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return File(dir, "$digest.jpg")
    }

    private companion object {
        /** 缩略图最长边目标（px），与 DocumentsUI 常用的请求尺寸同量级。 */
        const val THUMB_MAX_DIMENSION = 512

        /** 缩略图缓存文件数上限，超过即整目录清空。 */
        const val THUMB_CACHE_MAX_FILES = 128
    }

    override fun createDocument(
        parentDocumentId: String?,
        mimeType: String?,
        displayName: String?
    ): String {
        val parent = getFileForDocId(parentDocumentId ?: "")
        val file = File(parent, displayName ?: "unnamed")
        try {
            if (DocumentsContract.Document.MIME_TYPE_DIR == mimeType) {
                file.mkdirs()
            } else {
                file.createNewFile()
            }
        } catch (e: Exception) {
            throw FileNotFoundException("Failed to create document: ${e.message}")
        }
        return getDocIdForFile(file)
    }

    override fun deleteDocument(documentId: String?) {
        val file = getFileForDocId(documentId ?: "")
        if (!file.deleteRecursively()) {
            throw FileNotFoundException("Failed to delete document: $documentId")
        }
    }

    override fun isChildDocument(parentDocumentId: String?, documentId: String?): Boolean {
        if (parentDocumentId == null || documentId == null) return false
        val parent = getFileForDocId(parentDocumentId)
        val child = getFileForDocId(documentId)
        return child.absolutePath.startsWith(parent.absolutePath)
    }

    // Helper functions to map DocumentId to File path and vice versa
    private fun getFileForDocId(documentId: String): File {
        val target = if (documentId.startsWith("primary:")) {
            val relPath = documentId.substring("primary:".length)
            File("/storage/emulated/0", relPath)
        } else {
            File("/storage/emulated/0")
        }
        return target
    }

    private fun getDocIdForFile(file: File): String {
        val rootPath = "/storage/emulated/0"
        val path = file.absolutePath
        return if (path.startsWith(rootPath)) {
            var relPath = path.substring(rootPath.length)
            if (relPath.startsWith("/")) {
                relPath = relPath.substring(1)
            }
            "primary:$relPath"
        } else {
            "primary:"
        }
    }

    private fun includeFile(result: MatrixCursor, docId: String?, file: File) {
        val flags = DocumentsContract.Document.FLAG_SUPPORTS_DELETE or
                    DocumentsContract.Document.FLAG_SUPPORTS_WRITE

        val mimeType = getMimeType(file)
        val finalFlags = if (mimeType == DocumentsContract.Document.MIME_TYPE_DIR) {
            flags or DocumentsContract.Document.FLAG_DIR_SUPPORTS_CREATE
        } else {
            // 告诉 DocumentsUI 这个文档可以请求缩略图（openDocumentThumbnail），
            // 否则图片/视频在系统选择器里只显示通用 MIME 图标。
            flags or DocumentsContract.Document.FLAG_SUPPORTS_THUMBNAIL
        }

        val row = result.newRow()
        row.add(DocumentsContract.Document.COLUMN_DOCUMENT_ID, docId)
        row.add(DocumentsContract.Document.COLUMN_DISPLAY_NAME, file.name)
        row.add(DocumentsContract.Document.COLUMN_SIZE, file.length())
        row.add(DocumentsContract.Document.COLUMN_MIME_TYPE, mimeType)
        row.add(DocumentsContract.Document.COLUMN_LAST_MODIFIED, file.lastModified())
        row.add(DocumentsContract.Document.COLUMN_FLAGS, finalFlags)
    }

    private fun getMimeType(file: File): String {
        if (file.isDirectory) {
            return DocumentsContract.Document.MIME_TYPE_DIR
        }
        val name = file.name
        val lastDot = name.lastIndexOf('.')
        if (lastDot >= 0) {
            val extension = name.substring(lastDot + 1).lowercase()
            val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension)
            if (mime != null) return mime
        }
        return "application/octet-stream"
    }
}
