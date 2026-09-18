package com.example.tinode_flutter_test

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.example.tinode_flutter_test.tinode.TinodeBridge

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "tinode"
    }

    private lateinit var tinodeBridge: TinodeBridge

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        tinodeBridge = TinodeBridge()

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {

                "connect" -> {
                    tinodeBridge.connect(result)
                }

                "login" -> {
                    val username = call.argument<String>("username")
                    val password = call.argument<String>("password")
                    if (username.isNullOrBlank() || password.isNullOrEmpty()) {
                        result.error("INVALID_ARGUMENT", "Username and password are required", null)
                    } else {
                        tinodeBridge.login(username, password, result)
                    }
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
    }
}

