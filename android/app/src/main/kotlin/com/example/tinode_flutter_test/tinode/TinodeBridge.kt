package com.example.tinode_flutter_test.tinode

import co.tinode.tinodesdk.Tinode
import co.tinode.tinodesdk.PromisedReply
import co.tinode.tinodesdk.model.ServerMessage
import io.flutter.plugin.common.MethodChannel

private typealias TinodeMessage = ServerMessage<Any, Any, Any, Any>

class TinodeBridge {

    companion object {
        private const val APP_NAME = "tinode_flutter_test"
        private const val API_KEY = "AQEAAAABAAD_rAp4DJh05a1HAwFT3A6K"

        // 你的 Tinode Server
        private const val HOST = "119.29.246.172:6060"

        // 当前服务器是 HTTP，所以使用非 TLS WebSocket
        private const val TLS = false
    }

    private var tinode: Tinode? = null

    fun connect(result: MethodChannel.Result) {

        try {

            val listener = object : Tinode.EventListener {

                override fun onConnect(
                    code: Int,
                    reason: String?,
                    params: MutableMap<String, Any>?
                ) {
                    result.success(
                        mapOf(
                            "success" to true,
                            "code" to code,
                            "reason" to (reason ?: "")
                        )
                    )
                }

                override fun onDisconnect(
                    byServer: Boolean,
                    code: Int,
                    reason: String?
                ) {
                }
            }

            tinode = Tinode(
                APP_NAME,
                API_KEY,
                listener
            )

            tinode?.connect(
                HOST,
                TLS,
                false
            )

        } catch (e: Exception) {

            result.error(
                "TINODE_CONNECT_ERROR",
                e.message ?: "Tinode connect failed",
                null
            )
        }
    }

    fun login(username: String, password: String, result: MethodChannel.Result) {
        try {
            val client = tinode ?: Tinode(APP_NAME, API_KEY, object : Tinode.EventListener {})
                .also { tinode = it }

            val onLogin = object : PromisedReply.SuccessListener<TinodeMessage>() {
                override fun onSuccess(message: TinodeMessage?): PromisedReply<TinodeMessage>? {
                    result.success(
                        mapOf(
                            "success" to true,
                            "code" to (message?.ctrl?.code ?: 200),
                            "reason" to (message?.ctrl?.text ?: "OK"),
                            "uid" to (client.myId ?: "")
                        )
                    )
                    return null
                }
            }
            val onFailure = object : PromisedReply.FailureListener<TinodeMessage>() {
                override fun <E : Exception> onFailure(error: E): PromisedReply<TinodeMessage>? {
                    result.error(
                        "TINODE_LOGIN_ERROR",
                        error?.message ?: "Tinode login failed",
                        null
                    )
                    return null
                }
            }

            if (client.isConnected) {
                client.loginBasic(username, password)
                    .thenApply(onLogin)
                    .thenCatch(onFailure)
            } else {
                client.connect(HOST, TLS, false)
                    .thenApply(
                        object : PromisedReply.SuccessListener<TinodeMessage>() {
                            override fun onSuccess(message: TinodeMessage?): PromisedReply<TinodeMessage> {
                                return client.loginBasic(username, password)
                            }
                        }
                    )
                    .thenApply(onLogin)
                    .thenCatch(onFailure)
            }
        } catch (error: Exception) {
            result.error("TINODE_LOGIN_ERROR", error.message ?: "Tinode login failed", null)
        }
    }
}

