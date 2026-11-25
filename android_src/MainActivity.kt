package com.example.egba

import android.app.Activity
import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import android.view.KeyEvent
import android.view.View
import com.swordfish.libretrodroid.GLRetroView
import com.swordfish.libretrodroid.GLRetroViewData
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File

object Retro {
    var view: GLRetroView? = null
}

class RetroPlatformView(private val activity: MainActivity, rom: String) : PlatformView {
    private val retroView: GLRetroView

    init {
        val core = File(activity.applicationInfo.nativeLibraryDir, "libmgba_libretro_android.so")
        if (!core.exists()) {
            throw IllegalStateException("No se encontró el motor: " + core.absolutePath)
        }
        if (!File(rom).exists()) {
            throw IllegalStateException("No se encontró la ROM: $rom")
        }
        val data = GLRetroViewData(activity).apply {
            coreFilePath = core.absolutePath
            gameFilePath = rom
            systemDirectory = File(activity.filesDir, "system").apply { mkdirs() }.absolutePath
            savesDirectory = File(activity.filesDir, "saves").apply { mkdirs() }.absolutePath
        }
        retroView = GLRetroView(activity, data)
        activity.lifecycle.addObserver(retroView)
        Retro.view = retroView
    }

    override fun getView(): View = retroView

    override fun dispose() {
        activity.lifecycle.removeObserver(retroView)
        if (Retro.view === retroView) Retro.view = null
    }
}

class RetroViewFactory(private val activity: MainActivity) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        val rom = (args as Map<*, *>)["rom"] as String
        return RetroPlatformView(activity, rom)
    }
}

class MainActivity : FlutterActivity() {
    private var pendingPick: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Guarda el motivo si la app se cierra por un error.
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { t, e ->
            try {
                File(filesDir, "crash.txt").writeText(
                    "Hilo: " + t.name + "\n" + android.util.Log.getStackTraceString(e)
                )
            } catch (_: Exception) {
            }
            previous?.uncaughtException(t, e)
        }
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        flutterEngine.platformViewsController.registry
            .registerViewFactory("egba/retro_view", RetroViewFactory(this))

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gba/emulator")
            .setMethodCallHandler { call, result ->
                val v = Retro.view
                when (call.method) {
                    "pickRom" -> pickRom(result)
                    "getLastCrash" -> result.success(readLastCrash())
                    "setKey" -> {
                        val code = keyCode(call.argument<String>("key"))
                        val pressed = call.argument<Boolean>("pressed") == true
                        if (v != null && code != null) {
                            v.sendKeyEvent(
                                if (pressed) KeyEvent.ACTION_DOWN else KeyEvent.ACTION_UP,
                                code
                            )
                        }
                        result.success(null)
                    }
                    "reset" -> {
                        v?.reset()
                        result.success(null)
                    }
                    "setFastForward" -> {
                        v?.frameSpeed = if (call.argument<Boolean>("on") == true) 3 else 1
                        result.success(null)
                    }
                    "saveState" -> {
                        if (v != null) File(filesDir, "state.bin").writeBytes(v.serializeState())
                        result.success(null)
                    }
                    "loadState" -> {
                        val f = File(filesDir, "state.bin")
                        if (v != null && f.exists()) v.unserializeState(f.readBytes())
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    // Saca del informe del sistema las líneas útiles, descartando el ruido de Android.
    private fun tombstoneLines(info: ApplicationExitInfo): String {
        return try {
            val bytes = info.traceInputStream?.use { it.readBytes() } ?: return ""
            val lines = ArrayList<String>()
            val run = StringBuilder()
            for (b in bytes) {
                val c = b.toInt() and 0xFF
                if (c in 32..126) {
                    run.append(c.toChar())
                } else {
                    if (run.length >= 4) lines.add(run.toString())
                    run.setLength(0)
                }
            }
            if (run.length >= 4) lines.add(run.toString())

            val noise = listOf(
                "/apex/com.android.runtime", "libbinder", "libutils", "libandroid_runtime",
                "art::", "libart.so", "libc++", "libgui", "boot.oat", "dalvik-cache",
                "__pthread", "__start_thread", "java.lang.Thread", "android.os."
            )
            val useful = listOf(
                "SEGV", "SIG", "dereference", "Cause", "abort", "Abort", ".so", "retro",
                "mgba", "swordfish", "egba", "libflutter", "GL", "EGL", "fault", "Exception"
            )
            lines
                .filter { l -> noise.none { l.contains(it) } && useful.any { l.contains(it, true) } }
                .distinct()
                .take(60)
                .joinToString("\n") { it.take(120) }
        } catch (e: Exception) {
            "(no se pudo leer el informe: " + e.message + ")"
        }
    }

    private fun readLastCrash(): String? {
        val sb = StringBuilder()
        val f = File(filesDir, "crash.txt")
        if (f.exists()) {
            sb.append(f.readText().take(3000))
            f.delete()
        }
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                val last = am.getHistoricalProcessExitReasons(packageName, 0, 1).firstOrNull()
                if (last != null) {
                    val prefs = getSharedPreferences("egba", Context.MODE_PRIVATE)
                    if (prefs.getLong("last_exit_ts", 0L) != last.timestamp) {
                        prefs.edit().putLong("last_exit_ts", last.timestamp).apply()
                        val name = when (last.reason) {
                            2 -> "cerrada por una señal del sistema"
                            3 -> "poca memoria"
                            4 -> "error de la app (Java/Kotlin)"
                            5 -> "error nativo (probablemente el motor)"
                            6 -> "la app dejó de responder"
                            else -> null
                        }
                        if (name != null) {
                            sb.append("\nÚltimo cierre: ").append(name)
                            sb.append(" [código ").append(last.reason).append("]")
                            sb.append(" ").append(last.description ?: "")
                            sb.append("\nAndroid ").append(Build.VERSION.RELEASE)
                            sb.append(" / ").append(Build.SUPPORTED_ABIS.joinToString(","))
                            sb.append(" / ").append(Build.MANUFACTURER).append(" ").append(Build.MODEL)
                            if (last.reason == 5) {
                                val t = tombstoneLines(last)
                                if (t.isNotEmpty()) sb.append("\n\n").append(t)
                            }
                        }
                    }
                }
            } catch (_: Exception) {
            }
        }
        return if (sb.isEmpty()) null else sb.toString()
    }

    private fun keyCode(k: String?): Int? = when (k) {
        "a" -> KeyEvent.KEYCODE_BUTTON_A
        "b" -> KeyEvent.KEYCODE_BUTTON_B
        "l" -> KeyEvent.KEYCODE_BUTTON_L1
        "r" -> KeyEvent.KEYCODE_BUTTON_R1
        "start" -> KeyEvent.KEYCODE_BUTTON_START
        "select" -> KeyEvent.KEYCODE_BUTTON_SELECT
        "up" -> KeyEvent.KEYCODE_DPAD_UP
        "down" -> KeyEvent.KEYCODE_DPAD_DOWN
        "left" -> KeyEvent.KEYCODE_DPAD_LEFT
        "right" -> KeyEvent.KEYCODE_DPAD_RIGHT
        else -> null
    }

    private fun pickRom(result: MethodChannel.Result) {
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        startActivityForResult(intent, 4242)
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 4242) return
        val result = pendingPick ?: return
        pendingPick = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        Thread {
            try {
                var name = "game.gba"
                contentResolver.query(uri, null, null, null, null)?.use { c ->
                    val i = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (i >= 0 && c.moveToFirst()) name = c.getString(i)
                }
                val dir = File(filesDir, "roms").apply { mkdirs() }
                val out = File(dir, name.replace("/", "_"))
                contentResolver.openInputStream(uri)?.use { input ->
                    out.outputStream().use { input.copyTo(it) }
                }
                runOnUiThread { result.success(out.absolutePath) }
            } catch (e: Exception) {
                runOnUiThread { result.success(null) }
            }
        }.start()
    }
}
