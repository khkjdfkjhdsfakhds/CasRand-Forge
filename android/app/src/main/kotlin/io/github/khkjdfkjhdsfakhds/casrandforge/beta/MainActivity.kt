package io.github.khkjdfkjhdsfakhds.casrandforge.beta

import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
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

    private fun registerPlugin(name: String, block: () -> Unit) {
        try {
            block()
        } catch (error: Throwable) {
            Log.e(tag, "Error registering plugin $name", error)
        }
    }

    companion object {
        private const val tag = "CasRandPluginRegistrant"
    }
}
