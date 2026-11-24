package com.droidscreen.receiver

import android.content.Intent
import android.os.Bundle
import android.view.KeyEvent
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import com.droidscreen.receiver.session.StreamViewModel
import com.droidscreen.receiver.ui.DroidScreenApp

class MainActivity : ComponentActivity() {
    private val viewModel: StreamViewModel by viewModels()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        if (savedInstanceState == null) viewModel.onLaunch(intent)
        setContent {
            MaterialTheme(colorScheme = darkColorScheme()) {
                DroidScreenApp(viewModel)
            }
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean =
        viewModel.onKeyEvent(event) || super.dispatchKeyEvent(event)

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        viewModel.applyIntent(intent)
    }

    // The stream runs only while the activity is visible: backgrounding closes the connection
    // (the host then stops capturing); returning reconnects automatically.
    override fun onStart() {
        super.onStart()
        viewModel.onForeground()
    }

    override fun onStop() {
        viewModel.onBackground()
        super.onStop()
    }
}
