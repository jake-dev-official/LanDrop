package org.localsend.localsend_app

import android.content.Context
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
    /// share_handler drops share intents arriving via onNewIntent while the Dart side
    /// is not subscribed to its media stream yet, which happens when this singleTask
    /// activity is relaunched into an existing task while the app is still starting.
    /// Hold such intents back until Dart reports readiness ("shareIntentReady"), then
    /// replay them through the regular plugin path.
    private val pendingShareIntents = mutableListOf<Intent>()

    override fun onCreate(savedInstanceState: Bundle?) {
        LanDropEngineManager.ensureEngine(applicationContext)
        LanDropEngineManager.attachActivity(this)
        super.onCreate(savedInstanceState)
    }

    override fun getCachedEngineId(): String = LanDropEngineManager.ENGINE_ID

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onDestroy() {
        LanDropEngineManager.detachActivity(this)
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        if (!LanDropEngineManager.shareIntentReady &&
            (intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE)
        ) {
            pendingShareIntents.add(intent)
            return
        }
        super.onNewIntent(intent)
    }

    fun flushPendingShareIntents() {
        val pending = pendingShareIntents.toList()
        pendingShareIntents.clear()
        for (intent in pending) {
            super.onNewIntent(intent)
        }
    }

    // Overriding the static methods we need from the Java class, as described
    // in the documentation of `FlutterActivity.NewEngineIntentBuilder`
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
