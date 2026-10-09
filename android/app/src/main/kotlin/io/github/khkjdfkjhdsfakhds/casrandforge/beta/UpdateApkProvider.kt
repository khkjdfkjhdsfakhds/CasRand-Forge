package io.github.khkjdfkjhdsfakhds.casrandforge.beta

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException

/**
 * Read-only provider that exposes downloaded update packages from
 * `cache/updates/` to the system package installer.
 */
class UpdateApkProvider : ContentProvider() {
    override fun onCreate(): Boolean = true

    private fun fileFor(uri: Uri): File {
        val name = uri.lastPathSegment ?: throw FileNotFoundException(uri.toString())
        val dir = File(context!!.cacheDir, UPDATE_DIR).canonicalFile
        val file = File(dir, name).canonicalFile
        if (file.parentFile != dir || !file.name.endsWith(".apk") || !file.isFile) {
            throw FileNotFoundException(uri.toString())
        }
        return file
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("read-only")
        return ParcelFileDescriptor.open(fileFor(uri), ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri): String = APK_MIME

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?
    ): Cursor {
        val file = fileFor(uri)
        val columns: Array<String> = projection?.let { arrayOf(*it) }
            ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val cursor = MatrixCursor(columns)
        cursor.addRow(columns.map {
            when (it) {
                OpenableColumns.DISPLAY_NAME -> file.name
                OpenableColumns.SIZE -> file.length()
                else -> null
            }
        })
        return cursor
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?
    ): Int = 0

    companion object {
        const val UPDATE_DIR = "updates"
        const val APK_MIME = "application/vnd.android.package-archive"

        fun uriFor(authority: String, file: File): Uri =
            Uri.Builder().scheme("content").authority(authority).appendPath(file.name).build()
    }
}
