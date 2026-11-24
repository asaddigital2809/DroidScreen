package com.droidscreen.receiver.input

import android.content.Context
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import com.droidscreen.receiver.protocol.InputWire
import kotlin.math.hypot

enum class TouchMode { DIRECT, TRACKPAD }

/**
 * Turns touches on the video view into pointer/scroll messages.
 *
 * DIRECT (touchscreen):     tap = left click at the finger, second tap = double click,
 *                           long press = right click, one-finger drag = left-button drag,
 *                           two-finger drag = scroll.
 * TRACKPAD (relative):      one-finger drag moves the cursor, tap = left click at the cursor,
 *                           double tap = double click, long press = right click, two fingers = scroll.
 *
 * Positions are normalised to the view, which has exactly the video's aspect ratio.
 */
class TouchInputHandler(
    context: Context,
    private val modeProvider: () -> TouchMode,
    private val send: (ByteArray) -> Unit,
) : View.OnTouchListener {

    private enum class State { IDLE, PENDING, DRAGGING, MOVING, SCROLLING, LONG_PRESSED }

    private val slop = ViewConfiguration.get(context).scaledTouchSlop.toFloat()
    private val doubleTapTimeout = ViewConfiguration.getDoubleTapTimeout().toLong()
    private val longPressTimeout = 450L
    private val trackpadSensitivity = 1.5f

    private var state = State.IDLE
    private var mode = TouchMode.DIRECT
    private var downX = 0f
    private var downY = 0f
    private var lastX = 0f
    private var lastY = 0f
    private var lastTapTime = 0L
    private var lastTapX = 0f
    private var lastTapY = 0f
    private var tapCount = 0
    private var currentView: View? = null
    private var width = 1f
    private var height = 1f
    private val longPress = Runnable { onLongPress() }

    override fun onTouch(v: View, e: MotionEvent): Boolean {
        if (v.width <= 0 || v.height <= 0) return true
        currentView = v
        width = v.width.toFloat()
        height = v.height.toFloat()

        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                mode = modeProvider()
                state = State.PENDING
                downX = e.x; downY = e.y; lastX = e.x; lastY = e.y
                v.postDelayed(longPress, longPressTimeout)
                if (mode == TouchMode.DIRECT) send(InputWire.move(nx(e.x), ny(e.y)))
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                v.removeCallbacks(longPress)
                if (state == State.DRAGGING) send(InputWire.up(InputWire.LEFT, nx(lastX), ny(lastY), 1))
                state = State.SCROLLING
                centroid(e).let { lastX = it.first; lastY = it.second }
            }
            MotionEvent.ACTION_MOVE -> onMove(v, e)
            MotionEvent.ACTION_UP -> {
                v.removeCallbacks(longPress)
                when (state) {
                    State.PENDING -> tap(e.x, e.y)
                    State.DRAGGING -> send(InputWire.up(InputWire.LEFT, nx(e.x), ny(e.y), 1))
                    else -> {}
                }
                state = State.IDLE
            }
            MotionEvent.ACTION_CANCEL -> {
                v.removeCallbacks(longPress)
                if (state == State.DRAGGING) send(InputWire.up(InputWire.LEFT, nx(lastX), ny(lastY), 1))
                state = State.IDLE
            }
        }
        return true
    }

    private fun onMove(v: View, e: MotionEvent) {
        when (state) {
            State.PENDING -> {
                if (hypot(e.x - downX, e.y - downY) <= slop) return
                v.removeCallbacks(longPress)
                if (mode == TouchMode.DIRECT) {
                    state = State.DRAGGING
                    send(InputWire.down(InputWire.LEFT, nx(downX), ny(downY), 1))
                    send(InputWire.move(nx(e.x), ny(e.y)))
                } else {
                    state = State.MOVING
                    relativeMove(e.x, e.y)
                }
                lastX = e.x; lastY = e.y
            }
            State.DRAGGING -> {
                send(InputWire.move(nx(e.x), ny(e.y)))
                lastX = e.x; lastY = e.y
            }
            State.MOVING -> {
                relativeMove(e.x, e.y)
                lastX = e.x; lastY = e.y
            }
            State.SCROLLING -> {
                if (e.pointerCount < 2) return
                val (cx, cy) = centroid(e)
                send(InputWire.scroll((cx - lastX) / width, (cy - lastY) / height))
                lastX = cx; lastY = cy
            }
            State.LONG_PRESSED, State.IDLE -> {}
        }
    }

    private fun relativeMove(x: Float, y: Float) {
        send(InputWire.moveBy((x - lastX) / width * trackpadSensitivity, (y - lastY) / height * trackpadSensitivity))
    }

    private fun tap(x: Float, y: Float) {
        val now = System.currentTimeMillis()
        tapCount = if (now - lastTapTime <= doubleTapTimeout && hypot(x - lastTapX, y - lastTapY) <= slop * 4) minOf(tapCount + 1, 3) else 1
        lastTapTime = now; lastTapX = x; lastTapY = y
        if (mode == TouchMode.DIRECT) {
            send(InputWire.down(InputWire.LEFT, nx(x), ny(y), tapCount))
            send(InputWire.up(InputWire.LEFT, nx(x), ny(y), tapCount))
        } else {
            send(InputWire.downAtCursor(InputWire.LEFT, tapCount))
            send(InputWire.upAtCursor(InputWire.LEFT, tapCount))
        }
    }

    private fun onLongPress() {
        if (state != State.PENDING) return
        state = State.LONG_PRESSED
        currentView?.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        if (mode == TouchMode.DIRECT) {
            send(InputWire.down(InputWire.RIGHT, nx(downX), ny(downY), 1))
            send(InputWire.up(InputWire.RIGHT, nx(downX), ny(downY), 1))
        } else {
            send(InputWire.downAtCursor(InputWire.RIGHT, 1))
            send(InputWire.upAtCursor(InputWire.RIGHT, 1))
        }
    }

    private fun nx(x: Float) = (x / width).coerceIn(0f, 1f)
    private fun ny(y: Float) = (y / height).coerceIn(0f, 1f)

    private fun centroid(e: MotionEvent): Pair<Float, Float> {
        var sx = 0f
        var sy = 0f
        val n = minOf(e.pointerCount, 2)
        for (i in 0 until n) { sx += e.getX(i); sy += e.getY(i) }
        return sx / n to sy / n
    }
}
