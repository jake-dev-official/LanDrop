package org.localsend.localsend_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class LanDropBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action == Intent.ACTION_BOOT_COMPLETED || action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            try {
                LanDropEngineManager.ensureEngine(context.applicationContext)
            } catch (_: Exception) {
                // Boot initialization must never crash system broadcast handling.
            }
        }
    }
}
