package com.example.tinode_flutter_test.tinode

import co.tinode.tinodesdk.Tinode
import co.tinode.tinodesdk.PromisedReply
import co.tinode.tinodesdk.model.ServerMessage
import co.tinode.tinodesdk.model.MsgServerData
import co.tinode.tinodesdk.model.MsgServerPres
import co.tinode.tinodesdk.model.MsgServerMeta
import co.tinode.tinodesdk.model.TheCard
import co.tinode.tinodesdk.model.PrivateType
import co.tinode.tinodesdk.model.PrivateType
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

private typealias TinodeMessage = ServerMessage<Any, Any, Any, Any>

class TinodeBridge {

    companion object {
        private const val TAG = "TinodeBridge"
        private const val APP_NAME = "tinode_flutter_test"
        private const val API_KEY = "AQEAAAABAAD_rAp4DJh05a1HAwFT3A6K"

        // 你的 Tinode Server
        private const val HOST = "119.29.246.172:6060"

        // 当前服务器是 HTTP，所以使用非 TLS WebSocket
        private const val TLS = false
    }

    var tinode: Tinode? = null
        private set
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
        Log.d(TAG, "Event stream listening=${sink != null}")
    }

    fun emit(event: Map<String, Any?>) {
        mainHandler.post { eventSink?.success(event) }
    }

    fun attachments(content: co.tinode.tinodesdk.model.Drafty?): List<Map<String, Any?>> {
        return content?.ent?.mapNotNull { entity ->
            if (entity.tp !in listOf("IM", "EX", "AU", "VD")) return@mapNotNull null
            val data = entity.data ?: return@mapNotNull null
            mapOf("kind" to entity.tp, "name" to data["name"], "mime" to data["mime"],
                "ref" to data["ref"], "val" to data["val"], "size" to data["size"],
                "width" to data["width"], "height" to data["height"],
                "duration" to data["duration"], "preview" to data["preview"])
        } ?: emptyList()
    }

    private fun senderName(uid: String?): String {
        if (uid.isNullOrBlank()) return ""
        return tinode?.getUser<TheCard>(uid)?.pub?.fn ?: uid
    }

    private fun emitProfile(topicName: String?) {
        if (topicName.isNullOrBlank() || topicName in listOf(Tinode.TOPIC_ME, Tinode.TOPIC_FND, Tinode.TOPIC_SYS)) return
        val topic = tinode?.getTopic(topicName) ?: return
        val name = (topic.getPub() as? TheCard)?.fn ?: topicName
        emit(mapOf("type" to "profile", "topic" to topicName, "name" to name,
            "avatar" to avatar(topic.getPub() as? TheCard), "isGroup" to topic.isGrpType))
    }

    private fun avatar(card: TheCard?): Map<String, Any?>? {
        val photo = card?.photo ?: return null
        if (photo.data == null && photo.ref.isNullOrBlank()) return null
        return mapOf("val" to photo.data, "ref" to photo.ref,
            "mime" to card.photoMimeType, "name" to "avatar")
    }

    private fun createTinode(onConnected: ((Int, String?) -> Unit)? = null): Tinode {
        return Tinode(APP_NAME, API_KEY, object : Tinode.EventListener {
            override fun onConnect(code: Int, reason: String?, params: MutableMap<String, Any>?) {
                onConnected?.invoke(code, reason)
            }

            override fun onMetaMessage(meta: MsgServerMeta<*, *, *, *>) {
                // Tinode invokes this after updating its topic/user cache. An
                // "upd" presence packet alone does not contain the new name.
                if (meta.topic == Tinode.TOPIC_ME) {
                    meta.sub?.forEach { sub ->
                        if (sub.deleted == null) emitProfile(sub.topic)
                    }
                } else if (meta.desc != null) {
                    emitProfile(meta.topic)
                }
            }

            override fun onPresMessage(pres: MsgServerPres) {
                // Contact presence is addressed to "me"; src identifies the
                // conversation. Group participant presence is not topic presence.
                if (pres.topic != Tinode.TOPIC_ME) return
                if (pres.what != "on" && pres.what != "off") return
                val topicName = pres.src ?: return
                val online = pres.what == "on"
                mainHandler.post {
                    eventSink?.success(mapOf(
                        "type" to "presence",
                        "topic" to topicName,
                        "online" to online
                    ))
                }
            }

            override fun onDataMessage(data: MsgServerData) {
                Log.d(TAG, "Received data topic=${data.topic} seq=${data.seq}")
                val event = mapOf(
                    "type" to "message",
                    "topic" to (data.topic ?: ""),
                    "from" to (data.from ?: ""),
                    "sender" to senderName(data.from),
                    "self" to (tinode?.isMe(data.from) == true),
                    "seq" to data.seq,
                    "time" to (data.ts?.toString() ?: ""),
                    "attachments" to attachments(data.content),
                    "content" to (data.content?.toString() ?: "")
                )
                // Tinode invokes listeners on its WebSocket thread. Flutter's
                // EventChannel must send platform messages on the main thread.
                mainHandler.post {
                    Log.d(TAG, "Deliver data topic=${data.topic} seq=${data.seq} listening=${eventSink != null}")
                    eventSink?.success(event)
                }
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
                        "avatar" to avatar(topic.getPub() as? TheCard),
                        "isGroup" to topic.isGrpType,
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
            // Keep completion, timeout, and history collection on the same thread.
            var finished = false
            lateinit var listener: co.tinode.tinodesdk.Topic.Listener<Any, Any, Any, Any>
            lateinit var timeout: Runnable
            fun finish(error: Exception? = null) {
                if (finished) return
                finished = true
                mainHandler.removeCallbacks(timeout)
                topic.remListener(listener)
                if (error != null) {
                    Log.w(TAG, "Message subscription/history failed topic=$topicName", error)
                    result.error("TINODE_MESSAGES_ERROR", error.message ?: "Failed to load messages", null)
                } else {
                    messages.sortBy { (it["seq"] as? Int) ?: 0 }
                    Log.d(TAG, "History complete topic=$topicName count=${messages.size} attached=${topic.isAttached}")
                    result.success(messages)
                }
            }
            timeout = Runnable {
                finish(java.util.concurrent.TimeoutException("等待会话消息超时，请检查连接后重试"))
            }
            listener = object : co.tinode.tinodesdk.Topic.Listener<Any, Any, Any, Any> {
                override fun onData(data: MsgServerData) {
                    val message = mapOf(
                        "from" to (data.from ?: ""),
                        "sender" to senderName(data.from),
                        "self" to client.isMe(data.from),
                        "attachments" to attachments(data.content),
                        "content" to (data.content?.toString() ?: ""),
                        "seq" to data.seq,
                        "time" to (data.ts?.toString() ?: "")
                    )
                    mainHandler.post {
                        if (!finished) messages.add(message)
                    }
                }

                override fun onAllMessagesReceived(count: Int?) {
                    mainHandler.post { finish() }
                }
            }
            topic.addListener(listener)
            mainHandler.postDelayed(timeout, 15_000)
            try {
                Log.d(TAG, "Load messages topic=$topicName attached=${topic.isAttached} connected=${client.isConnected}")
                // Request only metadata used by this app. Completion is signalled
                // by the server's end-of-data packet, not the subscribe ACK.
                val query = topic.getMetaGetBuilder().withDesc().withSub()
                    .withData(null, null, 50).build()
                val request = if (topic.isAttached) {
                    topic.getMeta(query)
                } else {
                    topic.subscribe(null, query)
                }
                request.thenApply(object : PromisedReply.SuccessListener<TinodeMessage>() {
                    override fun onSuccess(message: TinodeMessage?): PromisedReply<TinodeMessage>? {
                        Log.d(TAG, "Message request acknowledged topic=$topicName attached=${topic.isAttached}")
                        return null
                    }
                }).thenCatch(object : PromisedReply.FailureListener<TinodeMessage>() {
                    override fun <E : Exception> onFailure(error: E): PromisedReply<TinodeMessage>? {
                        mainHandler.post { finish(error) }
                        return null
                    }
                })
            } catch (error: Exception) {
                finish(error)
            }
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

    fun updateGroup(topicName: String, name: String?, announcement: String?, alias: String?, result: MethodChannel.Result) {
        try {
            val client = tinode
            if (client == null || !client.isAuthenticated) {
                result.error("TINODE_NOT_LOGGED_IN", "Login is required", null)
                return
            }
            val topic = client.getTopic(topicName)
            if (topic == null || !topic.isGrpType) {
                result.error("TINODE_TOPIC_ERROR", "Unknown group: $topicName", null)
                return
            }
            val card = (topic.getPub() as? TheCard) ?: TheCard()
            if (name != null) card.fn = name
            val privateData = (topic.getPriv() as? PrivateType) ?: PrivateType()
            if (announcement != null) privateData.setComment(announcement)
            if (alias != null) privateData["alias"] = alias
            topic.setDescription(card, privateData, null)
                .thenApply(object : PromisedReply.SuccessListener<TinodeMessage>() {
                    override fun onSuccess(message: TinodeMessage?): PromisedReply<TinodeMessage>? {
                        mainHandler.post {
                            emitProfile(topicName)
                            result.success(null)
                        }
                        return null
                    }
                }).thenCatch(object : PromisedReply.FailureListener<TinodeMessage>() {
                    override fun <E : Exception> onFailure(error: E): PromisedReply<TinodeMessage>? {
                        mainHandler.post { result.error("TINODE_GROUP_UPDATE_ERROR", error.message ?: "Failed to update group", null) }
                        return null
                    }
                })
        } catch (error: Exception) {
            result.error("TINODE_GROUP_UPDATE_ERROR", error.message ?: "Failed to update group", null)
        }
    }

    fun leaveGroup(topicName: String, result: MethodChannel.Result) {
        try {
            val topic = tinode?.getTopic(topicName)
            if (topic == null || !topic.isGrpType) {
                result.error("TINODE_TOPIC_ERROR", "Unknown group: $topicName", null)
                return
            }
            topic.leave(true).thenApply(object : PromisedReply.SuccessListener<TinodeMessage>() {
                override fun onSuccess(message: TinodeMessage?): PromisedReply<TinodeMessage>? {
                    result.success(null)
                    return null
                }
            }).thenCatch(object : PromisedReply.FailureListener<TinodeMessage>() {
                override fun <E : Exception> onFailure(error: E): PromisedReply<TinodeMessage>? {
                    result.error("TINODE_GROUP_LEAVE_ERROR", error.message ?: "Failed to leave group", null)
                    return null
                }
            })
        } catch (error: Exception) {
            result.error("TINODE_GROUP_LEAVE_ERROR", error.message ?: "Failed to leave group", null)
        }
    }
}
