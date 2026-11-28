package org.localsend.localsend_app

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle

class DirectShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val incoming = intent
        val action = incoming?.action
        if (action == Intent.ACTION_SEND || action == Intent.ACTION_SEND_MULTIPLE) {
            val shortcutId = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                incoming.getStringExtra(Intent.EXTRA_SHORTCUT_ID)
            } else {
                null
            }
            val isDirectShare = shortcutId != null && shortcutId.startsWith(LanDropEngineManager.SHORTCUT_ID_PREFIX)

            LanDropEngineManager.ensureEngine(applicationContext)
            LanDropEngineManager.handleIncomingShareIntent(this, incoming, fromDirectShare = isDirectShare)

            if (!isDirectShare) {
                val mainIntent = Intent(this, MainActivity::class.java).apply {
                    this.action = Intent.ACTION_MAIN
                    addFlags(
                        Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP or
                            Intent.FLAG_ACTIVITY_CLEAR_TOP
                    )
                }
                startActivity(mainIntent)
            }
        }
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }
}
