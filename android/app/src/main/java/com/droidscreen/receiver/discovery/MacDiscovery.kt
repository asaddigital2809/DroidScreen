package com.droidscreen.receiver.discovery

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import android.util.Log
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.net.Inet4Address

/** A Mac host found on the local network. */
data class DiscoveredMac(val name: String, val host: String, val port: Int)

/**
 * Finds Mac hosts on the local network with DNS-SD (NsdManager). The Mac advertises
 * [SERVICE_TYPE] while "Allow Wi-Fi/LAN connections" or auto-stream is on.
 *
 * Services are resolved one at a time (NsdManager allows a single resolve in flight on older
 * Android versions). IPv4 addresses are preferred.
 */
class MacDiscovery(context: Context) {
    private val nsd = context.applicationContext.getSystemService(NsdManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val _hosts = MutableStateFlow<List<DiscoveredMac>>(emptyList())
    val hosts: StateFlow<List<DiscoveredMac>> = _hosts.asStateFlow()

    private var listener: NsdManager.DiscoveryListener? = null
    private val pending = ArrayDeque<NsdServiceInfo>()
    private var resolving = false

    val isRunning: Boolean get() = listener != null

    fun start() {
        main.post {
            if (listener != null) return@post
            val l = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(serviceType: String) { Log.i(TAG, "discovery started") }
                override fun onDiscoveryStopped(serviceType: String) { Log.i(TAG, "discovery stopped") }
                override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                    Log.w(TAG, "start discovery failed: $errorCode")
                    main.post { if (listener === this) listener = null }
                }
                override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) { Log.w(TAG, "stop discovery failed: $errorCode") }
                override fun onServiceFound(info: NsdServiceInfo) = main.post { enqueue(info) }.let {}
                override fun onServiceLost(info: NsdServiceInfo) = main.post {
                    _hosts.value = _hosts.value.filterNot { it.name == info.serviceName }
                }.let {}
            }
            listener = l
            runCatching { nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l) }
                .onFailure { Log.w(TAG, "discoverServices: $it"); listener = null }
        }
    }

    fun stop() {
        main.post {
            val l = listener ?: return@post
            listener = null
            pending.clear()
            runCatching { nsd.stopServiceDiscovery(l) }
            _hosts.value = emptyList()
        }
    }

    private fun enqueue(info: NsdServiceInfo) {
        if (listener == null) return
        pending.addLast(info)
        resolveNext()
    }

    @Suppress("DEPRECATION") // resolveService / NsdServiceInfo.host: still supported, needed for API 29–33.
    private fun resolveNext() {
        if (resolving) return
        val info = pending.removeFirstOrNull() ?: return
        resolving = true
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) = main.post {
                Log.w(TAG, "resolve ${serviceInfo.serviceName} failed: $errorCode")
                resolving = false
                resolveNext()
            }.let {}

            override fun onServiceResolved(serviceInfo: NsdServiceInfo) = main.post {
                resolving = false
                val address = preferredAddress(serviceInfo)
                if (address != null && listener != null) {
                    val mac = DiscoveredMac(serviceInfo.serviceName, address, serviceInfo.port)
                    _hosts.value = _hosts.value.filterNot { it.name == mac.name } + mac
                    Log.i(TAG, "found $mac")
                }
                resolveNext()
            }.let {}
        })
    }

    @Suppress("DEPRECATION")
    private fun preferredAddress(info: NsdServiceInfo): String? {
        val addresses = if (android.os.Build.VERSION.SDK_INT >= 34) info.hostAddresses else listOfNotNull(info.host)
        val chosen = addresses.firstOrNull { it is Inet4Address } ?: addresses.firstOrNull()
        return chosen?.hostAddress
    }

    companion object {
        /** Must match `WireProtocol.bonjourServiceType` on the Mac. */
        const val SERVICE_TYPE = "_droidscreen._tcp"
        private const val TAG = "DroidScreenDiscovery"
    }
}
