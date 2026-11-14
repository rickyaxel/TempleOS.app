package io.github.templeosmobile.android

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.system.ErrnoException
import android.system.OsConstants
import android.util.Log
import io.github.templeosmobile.core.ui.FileImport
import io.github.templeosmobile.core.ui.ImportError
import io.github.templeosmobile.core.ui.PickedFile
import java.io.File
import java.io.IOException
import java.util.UUID

/**
 * Start menu > Import... on Android: the Storage Access Framework picker (ACTION_OPEN_DOCUMENT), which shows local
 * storage and every installed document provider (Downloads, Drive, USB storage...) without any storage permission.
 * Each chosen document is copied once, on a background thread, from its content URI into this app's cache (never read
 * in place, never through a file path, no persistable grant kept), and the copies go to the shell's ImportFlow, which
 * deletes them. Providers report .HC and .HC.Z with arbitrary MIME types, so the picker offers every type and
 * core's FileImport decides by the document's display name and checks the contents itself.
 *
 * The result can reach a new activity instance (the process was ended while the picker was open): [onResult] then
 * still hands the documents over, since ImportFlow accepts a result without a pending request.
 */
class DocumentImportAdapter(private val activity: Activity, private val deliver: (List<PickedFile>) -> Unit) {
    private var open = false

    /** Shows the picker (UI thread). False when there is none on this device or one is already open. */
    fun present(): Boolean {
        if (open) return false
        // copies left by an import the process did not live to finish (a copy in progress is never this old)
        val now = System.currentTimeMillis()
        File(activity.cacheDir, "import").listFiles()?.filter { now - it.lastModified() > 10 * 60_000L }?.forEach { it.delete() }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT)
            .addCategory(Intent.CATEGORY_OPENABLE)
            .setType("*/*")
            .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        return try {
            activity.startActivityForResult(intent, REQUEST)
            open = true
            true
        } catch (e: ActivityNotFoundException) {
            Log.w(TAG, "no document picker", e)
            false
        }
    }

    /** From Activity.onActivityResult; true when it was the picker's result. */
    fun onResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST) return false
        open = false
        val uris = ArrayList<Uri>()
        if (resultCode == Activity.RESULT_OK && data != null) {
            val clip = data.clipData
            if (clip != null) for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { uris.add(it) }
            else data.data?.let { uris.add(it) }
        }
        if (uris.isEmpty()) { deliver(emptyList()); return true }
        // only as many as one import takes are copied; the rest are reported by name
        Thread({
            deliver(uris.take(FileImport.MAX_PICKED).map { copy(it) } +
                uris.drop(FileImport.MAX_PICKED).map { PickedFile(displayName(it), null, ImportError("import.error.too_many_files", "count" to FileImport.MAX_PICKED)) })
        }, "TempleOS-ImportCopy").apply { isDaemon = true }.start()
        return true
    }

    /** The provider's display name and size (-1 when unknown). */
    private fun describe(uri: Uri): Pair<String, Long> {
        var name: String? = null
        var size = -1L
        try {
            activity.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    if (!c.isNull(0)) name = c.getString(0)
                    if (!c.isNull(1)) size = c.getLong(1)
                }
            }
        } catch (e: Exception) { Log.w(TAG, "document name", e) } // SecurityException, a provider that failed
        return (name ?: uri.lastPathSegment?.substringAfterLast('/') ?: "?") to size
    }

    private fun displayName(uri: Uri) = describe(uri).first

    /** One document, copied into the cache with a size limit; or why it could not be. Background thread. */
    private fun copy(uri: Uri): PickedFile {
        val resolver = activity.contentResolver
        val (shown, size) = describe(uri)
        // nothing larger than the largest accepted input is copied (FileImport checks each kind's own limit)
        val max = maxOf(FileImport.MAX_ARCHIVE_BYTES, FileImport.MAX_FILE_BYTES).toLong()
        if (size > max) return PickedFile(shown, null, ImportError("import.error.too_large", "mib" to (max shr 20)))
        val dir = File(activity.cacheDir, "import").apply { mkdirs() }
        val out = File(dir, UUID.randomUUID().toString())
        try {
            val input = resolver.openInputStream(uri) ?: return PickedFile(shown, null, ImportError("import.error.read"))
            input.use { src ->
                out.outputStream().use { dst ->
                    val buf = ByteArray(1 shl 16)
                    var total = 0L
                    while (true) {
                        val n = src.read(buf)
                        if (n < 0) break
                        total += n
                        if (total > max) { dst.close(); out.delete(); return PickedFile(shown, null, ImportError("import.error.too_large", "mib" to (max shr 20))) }
                        dst.write(buf, 0, n)
                    }
                }
            }
            return PickedFile(shown, out.path)
        } catch (e: IOException) {
            out.delete()
            Log.w(TAG, "copy failed", e)
            return PickedFile(shown, null, ImportError(if (noSpace(e)) "import.error.device_storage" else "import.error.read"))
        } catch (e: Exception) { // SecurityException (the grant is gone), IllegalArgumentException, a provider's own failures
            out.delete()
            Log.w(TAG, "copy failed", e)
            return PickedFile(shown, null, ImportError("import.error.read"))
        }
    }

    private fun noSpace(e: Throwable): Boolean {
        var t: Throwable? = e
        while (t != null) {
            if (t is ErrnoException && t.errno == OsConstants.ENOSPC) return true
            if (t.message?.contains("ENOSPC") == true || t.message?.contains("No space left") == true) return true
            t = t.cause
        }
        return false
    }

    companion object {
        private const val TAG = "TempleOSImport"
        /** startActivityForResult request code of the picker. */
        const val REQUEST = 0x7E31
    }
}
