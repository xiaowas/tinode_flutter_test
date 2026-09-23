package com.example.tinode_flutter_test

import android.content.Intent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import com.example.tinode_flutter_test.tinode.TinodeBridge
import com.example.tinode_flutter_test.tinode.MediaBridge

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "tinode"
    }

    private lateinit var tinodeBridge: TinodeBridge
    private lateinit var mediaBridge: MediaBridge

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        tinodeBridge = TinodeBridge()
        mediaBridge = MediaBridge(this, tinodeBridge)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tinode/media")
            .setMethodCallHandler { call, result -> mediaBridge.handle(call, result) }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL
        ).setMethodCallHandler { call, result ->

            when (call.method) {

                "connect" -> {
                    tinodeBridge.connect(result)
                }

                "listChats" -> {
                    tinodeBridge.listChats(result)
                }

                "getSession" -> {
                    tinodeBridge.getSession(result)
                }

                "sendMessage" -> {
                    val topic = call.argument<String>("topic")
                    val content = call.argument<String>("content")
                    if (topic.isNullOrBlank() || content.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENT", "Topic and content are required", null)
                    } else {
                        tinodeBridge.sendMessage(topic, content, result)
                    }
                }

                "getMessages" -> {
                    val topic = call.argument<String>("topic")
                    if (topic.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENT", "Topic is required", null)
                    } else {
                        tinodeBridge.getMessages(topic, result)
                    }
                }

                "markRead" -> {
                    val topic = call.argument<String>("topic")
                    if (topic.isNullOrBlank()) {
                        result.error("INVALID_ARGUMENT", "Topic is required", null)
                    } else {
                        tinodeBridge.markRead(topic, result)
                    }
                }

                "updateGroup" -> {
                    val topic = call.argument<String>("topic")
                    if (topic.isNullOrBlank()) result.error("INVALID_ARGUMENT", "Topic is required", null)
                    else tinodeBridge.updateGroup(topic, call.argument("name"), call.argument("announcement"), call.argument("alias"), result)
                }

                "leaveGroup" -> {
                    val topic = call.argument<String>("topic")
                    if (topic.isNullOrBlank()) result.error("INVALID_ARGUMENT", "Topic is required", null)
                    else tinodeBridge.leaveGroup(topic, result)
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

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "tinode/events"
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                tinodeBridge.setEventSink(events)
            }

            override fun onCancel(arguments: Any?) {
                tinodeBridge.setEventSink(null)
            }
        })
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (::mediaBridge.isInitialized && mediaBridge.onActivityResult(requestCode, resultCode, data)) return
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        if (::mediaBridge.isInitialized && mediaBridge.onPermissionResult(requestCode, grantResults)) return
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onPause() {
        if (::mediaBridge.isInitialized) mediaBridge.pause()
        super.onPause()
    }

    override fun onDestroy() {
        if (::mediaBridge.isInitialized) mediaBridge.dispose()
        super.onDestroy()
    }
}
