package org.localsend.localsend_app

import android.app.Activity
import android.content.Intent
import android.os.Bundle

class DirectShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val action = intent?.action
        if (action == Intent.ACTION_SEND || action == Intent.ACTION_SEND_MULTIPLE) {
            LanDropEngineManager.ensureEngine(applicationContext)
            LanDropEngineManager.handleIncomingShareIntent(this, intent, fromDirectShare = true)
        }
        finish()
        @Suppress("DEPRECATION")
        overridePendingTransition(0, 0)
    }
}
