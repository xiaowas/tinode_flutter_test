package com.example.tinode_flutter_test.tinode

import co.tinode.tinodesdk.Tinode
import co.tinode.tinodesdk.PromisedReply
import co.tinode.tinodesdk.model.ServerMessage
import co.tinode.tinodesdk.model.MsgServerData
import co.tinode.tinodesdk.model.TheCard
import co.tinode.tinodesdk.model.PrivateType
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
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
    private var eventSink: EventChannel.EventSink? = null

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    private fun senderName(uid: String?): String {
        if (uid.isNullOrBlank()) return ""
        return tinode?.getUser<TheCard>(uid)?.pub?.fn ?: uid
    }

    private fun createTinode(onConnected: ((Int, String?) -> Unit)? = null): Tinode {
        return Tinode(APP_NAME, API_KEY, object : Tinode.EventListener {
            override fun onConnect(code: Int, reason: String?, params: MutableMap<String, Any>?) {
                onConnected?.invoke(code, reason)
            }

            override fun onDataMessage(data: MsgServerData) {
                eventSink?.success(
                    mapOf(
                        "type" to "message",
                        "topic" to (data.topic ?: ""),
                        "from" to (data.from ?: ""),
                        "sender" to senderName(data.from),
                        "self" to (tinode?.isMe(data.from) == true),
                        "seq" to data.seq,
                        "time" to (data.ts?.toString() ?: ""),
                        "content" to (data.content?.toString() ?: "")
                    )
                )
            }
        }).also { client ->
            // Tinode's metadata packets are generic; configure the same payload
            // types used by the official Android client before parsing responses.
            client.setDefaultTypeOfMetaPacket(TheCard::class.java, PrivateType::class.java)
            client.setMeTypeOfMetaPacket(TheCard::class.java)
            client.setFndTypeOfMetaPacket(TheCard::class.java)
        }
    }

    fun connect(result: MethodChannel.Result) {

        try {

            tinode = createTinode { code, reason ->
                result.success(mapOf("success" to true, "code" to code, "reason" to (reason ?: "")))
            }

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
            val client = tinode ?: createTinode()
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

    fun listChats(result: MethodChannel.Result) {
        try {
            val client = tinode
            if (client == null || !client.isAuthenticated) {
                result.error("TINODE_NOT_LOGGED_IN", "Login is required", null)
                return
            }
            val me = client.getOrCreateMeTopic<Any>()
            var finished = false
            fun finish() {
                if (finished) return
                finished = true
                val chats = client.getTopics().mapNotNull { topic ->
                    val name = topic.name ?: return@mapNotNull null
                    if (name == Tinode.TOPIC_ME || name == Tinode.TOPIC_FND || name == Tinode.TOPIC_SYS) {
                        return@mapNotNull null
                    }
                    mapOf(
                        "topic" to name,
                        "name" to ((topic.getPub() as? TheCard)?.fn ?: name),
                        "online" to topic.online,
                        "unread" to topic.unreadCount,
                        "initial" to ((topic.getPub() as? TheCard)?.fn ?: name).firstOrNull()?.uppercase()
                    )
                }
                result.success(chats)
            }
            val listener = object : co.tinode.tinodesdk.MeTopic.MeListener<Any>() {
                override fun onSubsUpdated() {
                    me.remListener(this)
                    finish()
                }
            }
            me.addListener(listener)
            val onFailure = object : PromisedReply.FailureListener<TinodeMessage>() {
                override fun <E : Exception> onFailure(error: E): PromisedReply<TinodeMessage>? {
                    me.remListener(listener)
                    result.error("TINODE_CHATS_ERROR", error.message ?: "Failed to load chats", null)
                    return null
                }
            }
            val request = if (me.isAttached) {
                me.getMeta(me.getMetaGetBuilder().withDesc().withSub().build())
            } else {
                me.subscribe(null, me.getMetaGetBuilder().withDesc().withSub().build())
            }
            request.thenApply(object : PromisedReply.SuccessListener<TinodeMessage>() {
                override fun onSuccess(message: TinodeMessage?): PromisedReply<TinodeMessage>? {
                    Handler(Looper.getMainLooper()).postDelayed({ finish() }, 120)
                    return null
                }
            }).thenCatch(onFailure)
        } catch (error: Exception) {
            result.error("TINODE_CHATS_ERROR", error.message ?: "Failed to load chats", null)
        }
    }

    fun getSession(result: MethodChannel.Result) {
        val client = tinode
        result.success(
            mapOf(
                "authenticated" to (client?.isAuthenticated == true),
                "uid" to (client?.myId ?: "")
            )
        )
    }

    fun sendMessage(topicName: String, content: String, result: MethodChannel.Result) {
        try {
            val client = tinode
            if (client == null || !client.isAuthenticated) {
                result.error("TINODE_NOT_LOGGED_IN", "Login is required", null)
                return
            }
            val topic = client.getTopic(topicName)
            if (topic == null) {
                result.error("TINODE_TOPIC_ERROR", "Unknown topic: $topicName", null)
                return
            }
            @Suppress("UNCHECKED_CAST")
            val publish = topic.publish(content) as PromisedReply<TinodeMessage>
            publish
                .thenApply(object : PromisedReply.SuccessListener<TinodeMessage>() {
                    override fun onSuccess(message: TinodeMessage?): PromisedReply<TinodeMessage>? {
                        result.success(mapOf("success" to true, "topic" to topicName))
                        return null
                    }
                })
                .thenCatch(object : PromisedReply.FailureListener<TinodeMessage>() {
                    override fun <E : Exception> onFailure(error: E): PromisedReply<TinodeMessage>? {
                        result.error("TINODE_SEND_ERROR", error.message ?: "Failed to send message", null)
                        return null
                    }
                })
        } catch (error: Exception) {
            result.error("TINODE_SEND_ERROR", error.message ?: "Failed to send message", null)
        }
    }

    fun getMessages(topicName: String, result: MethodChannel.Result) {
        try {
            val client = tinode
            if (client == null || !client.isAuthenticated) {
                result.error("TINODE_NOT_LOGGED_IN", "Login is required", null)
                return
            }
            val topic = client.getTopic(topicName)
            if (topic == null) {
                result.error("TINODE_TOPIC_ERROR", "Unknown topic: $topicName", null)
                return
            }
            val messages = mutableListOf<Map<String, Any?>>()
            var finished = false
            lateinit var listener: co.tinode.tinodesdk.Topic.Listener<Any, Any, Any, Any>
            fun finish() {
                if (finished) return
                finished = true
                topic.remListener(listener)
                messages.sortBy { (it["seq"] as? Int) ?: 0 }
                topic.noteRecv()
                result.success(messages)
            }
            listener = object : co.tinode.tinodesdk.Topic.Listener<Any, Any, Any, Any> {
                override fun onData(data: MsgServerData) {
                    messages.add(
                        mapOf(
                            "from" to (data.from ?: ""),
                            "sender" to senderName(data.from),
                            "self" to client.isMe(data.from),
                            "content" to (data.content?.toString() ?: ""),
                            "seq" to data.seq,
                            "time" to (data.ts?.toString() ?: "")
                        )
                    )
                }

                override fun onAllMessagesReceived(count: Int?) {
                    finish()
                }
            }
            topic.addListener(listener)
            val request = if (topic.isAttached) {
                client.getMeta(topicName, topic.getMetaGetBuilder().withEarlierData(50).build())
            } else {
                topic.subscribe(
                    null,
                    topic.getMetaGetBuilder()
                        .withDesc()
                        .withSub()
                        .withEarlierData(24)
                        .withDel()
                        .withAux()
                        .build()
                )
            }
            request.thenFinally(object : PromisedReply.FinalListener() {
                override fun onFinally() {
                    Handler(Looper.getMainLooper()).postDelayed({ finish() }, 250)
                }
            })
        } catch (error: Exception) {
            result.error("TINODE_MESSAGES_ERROR", error.message ?: "Failed to load messages", null)
        }
    }

    fun markRead(topicName: String, result: MethodChannel.Result) {
        val topic = tinode?.getTopic(topicName)
        if (topic == null) {
            result.error("TINODE_TOPIC_ERROR", "Unknown topic: $topicName", null)
            return
        }
        topic.noteRead()
        result.success(null)
    }
}

