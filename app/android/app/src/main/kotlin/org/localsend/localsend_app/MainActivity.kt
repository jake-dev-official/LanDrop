package org.localsend.localsend_app

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        LanDropEngineManager.ensureEngine(applicationContext)
        LanDropEngineManager.attachActivity(this)
        val launchIntent = intent
        if (launchIntent?.action == Intent.ACTION_SEND || launchIntent?.action == Intent.ACTION_SEND_MULTIPLE) {
            LanDropEngineManager.handleIncomingShareIntent(this, launchIntent, fromDirectShare = false)
            // Replace with ACTION_MAIN so share_handler doesn't copy shared files to cache on the UI thread.
            setIntent(Intent(this, MainActivity::class.java).setAction(Intent.ACTION_MAIN))
        }
        super.onCreate(savedInstanceState)
    }

    override fun getCachedEngineId(): String = LanDropEngineManager.ENGINE_ID

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onDestroy() {
        LanDropEngineManager.detachActivity(this)
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        if (intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE) {
            LanDropEngineManager.handleIncomingShareIntent(this, intent, fromDirectShare = false)
            return
        }
        super.onNewIntent(intent)
    }

    companion object {
        fun withNewEngine(): NewEngineIntentBuilder {
            return NewEngineIntentBuilder(MainActivity::class.java)
        }

        fun createDefaultIntent(launchContext: Context): Intent {
            return withNewEngine().build(launchContext)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        LanDropEngineManager.handleRequestPermissionsResult(requestCode, grantResults)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        LanDropEngineManager.handleActivityResult(requestCode, resultCode, data)
    }
}
