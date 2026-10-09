package io.github.khkjdfkjhdsfakhds.casrandforge.beta

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updateChannel)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "installApk" -> result.success(
                            installApk(call.argument<String>("path") ?: "")
                        )
                        "openInstallPermissionSettings" -> {
                            openInstallPermissionSettings()
                            result.success(null)
                        }
                        else -> result.notImplemented()
                    }
                } catch (error: Throwable) {
                    result.error("update_failed", error.message, null)
                }
            }
        registerPlugin("device_info_plus") {
            flutterEngine.plugins.add(
                dev.fluttercommunity.plus.device_info.DeviceInfoPlusPlugin()
            )
        }
        registerPlugin("file_picker") {
            flutterEngine.plugins.add(com.mr.flutter.plugin.filepicker.FilePickerPlugin())
        }
        registerPlugin("flutter_plugin_android_lifecycle") {
            flutterEngine.plugins.add(
                io.flutter.plugins.flutter_plugin_android_lifecycle.FlutterAndroidLifecyclePlugin()
            )
        }
        registerPlugin("image_picker_android") {
            flutterEngine.plugins.add(io.flutter.plugins.imagepicker.ImagePickerPlugin())
        }
        registerPlugin("irondash_engine_context") {
            flutterEngine.plugins.add(
                dev.irondash.engine_context.IrondashEngineContextPlugin()
            )
        }
        registerPlugin("package_info_plus") {
            flutterEngine.plugins.add(dev.fluttercommunity.plus.packageinfo.PackageInfoPlugin())
        }
        registerPlugin("path_provider_android") {
            flutterEngine.plugins.add(io.flutter.plugins.pathprovider.PathProviderPlugin())
        }
        registerPlugin("permission_handler_android") {
            flutterEngine.plugins.add(com.baseflow.permissionhandler.PermissionHandlerPlugin())
        }
        registerPlugin("saver_gallery") {
            flutterEngine.plugins.add(com.mhz.savegallery.saver_gallery.SaverGalleryPlugin())
        }
        registerPlugin("shared_preferences_android") {
            flutterEngine.plugins.add(io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin())
        }
        registerPlugin("super_native_extensions") {
            flutterEngine.plugins.add(
                com.superlist.super_native_extensions.SuperNativeExtensionsPlugin()
            )
        }
        registerPlugin("url_launcher_android") {
            flutterEngine.plugins.add(io.flutter.plugins.urllauncher.UrlLauncherPlugin())
        }
    }

    private fun canInstallPackages(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
            packageManager.canRequestPackageInstalls()

    private fun openInstallPermissionSettings() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        startActivity(
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName")
            )
        )
    }

    private fun installApk(path: String): String {
        val file = File(path)
        if (!file.isFile) throw IllegalArgumentException("APK not found")
        if (!canInstallPackages()) {
            openInstallPermissionSettings()
            return "permission_required"
        }
        val uri = UpdateApkProvider.uriFor("$packageName.updates", file)
        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, UpdateApkProvider.APK_MIME)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
        return "started"
    }

    private fun registerPlugin(name: String, block: () -> Unit) {
        try {
            block()
        } catch (error: Throwable) {
            Log.e(tag, "Error registering plugin $name", error)
        }
    }

    companion object {
        private const val tag = "CasRandPluginRegistrant"
        private const val updateChannel =
            "io.github.khkjdfkjhdsfakhds.casrandforge/app_update"
    }
}
