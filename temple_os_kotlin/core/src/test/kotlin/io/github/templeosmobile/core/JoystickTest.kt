package io.github.templeosmobile.core

import io.github.templeosmobile.core.holyc.GlobalSym
import io.github.templeosmobile.core.kernel.*
import io.github.templeosmobile.core.ui.*
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import java.io.File

/**
 * The joystick that can stand in for the d-pad (GameControls, Settings.directional): it exists only where the
 * program has the d-pad, it holds the same arrow keys through the same key path (down, typematic repeat, up), it
 * sends only what changes, and nothing it holds outlives its finger, its mode or its place on the screen.
 */
class JoystickTest {
    private val U = Joystick.UP; private val D = Joystick.DOWN; private val L = Joystick.LEFT; private val R = Joystick.RIGHT

    @Test fun pushesMapToArrows() {
        val t = 36
        assertEquals(R, Joystick.keys(30, 0, t, 0))
        assertEquals(L, Joystick.keys(-30, 0, t, 0))
        assertEquals("y grows downwards", U, Joystick.keys(0, -30, t, 0))
        assertEquals(D, Joystick.keys(0, 30, t, 0))
        assertEquals(U or R, Joystick.keys(20, -20, t, 0))
        assertEquals(U or L, Joystick.keys(-20, -20, t, 0))
        assertEquals(D or L, Joystick.keys(-20, 20, t, 0))
        assertEquals(D or R, Joystick.keys(20, 20, t, 0))
        // arrows own 30 degrees either side of their axis, diagonals the 30 between
        assertEquals("27 degrees: still right", R, Joystick.keys(100, -50, t, 0))
        assertEquals("39 degrees: a diagonal", U or R, Joystick.keys(100, -80, t, 0))
        assertEquals("63 degrees: up", U, Joystick.keys(50, -100, t, 0))
        assertEquals("far beyond the rim: still the direction of the push", L, Joystick.keys(-200, 1, t, 0))
    }

    @Test fun deadZoneAndHysteresis() {
        val t = 40 // engages at 24 px, lets go below 17.6 px
        assertEquals(0, Joystick.keys(0, 0, t, 0))
        assertEquals("inside the dead zone", 0, Joystick.keys(23, 0, t, 0))
        assertEquals("at its edge", R, Joystick.keys(24, 0, t, 0))
        assertEquals("a held push stays down a little inside the edge", R, Joystick.keys(18, 0, t, R))
        assertEquals("and lets go further in", 0, Joystick.keys(17, 0, t, R))
        assertEquals("a new push needs the full distance", 0, Joystick.keys(20, 0, t, 0))
        // a held direction is kept 6 degrees past its sector's edge
        fun at(deg: Double) = (100 * Math.cos(Math.toRadians(deg))).toInt() to -(100 * Math.sin(Math.toRadians(deg))).toInt()
        val a33 = at(33.0); val a40 = at(40.0); val a26 = at(26.0)
        assertEquals("33 degrees is a diagonal", U or R, Joystick.keys(a33.first, a33.second, t, 0))
        assertEquals("but right stays right there", R, Joystick.keys(a33.first, a33.second, t, R))
        assertEquals("until the push is past the margin", U or R, Joystick.keys(a40.first, a40.second, t, R))
        assertEquals("a diagonal is kept 6 degrees into the arrow's sector", U or R, Joystick.keys(a26.first, a26.second, t, U or R))
        assertEquals(R, Joystick.keys(a26.first, a26.second, t, 0))
    }

    /** Settings > Joystick sensitivity: each level up holds from a shorter push; the default needs twice the highest level's. */
    @Test fun theSensitivitySetsTheDeadZone() {
        val t = 40
        // level -> the shortest push that holds, and the shortest held push that stays (90/66 ... 30/22 % of the travel)
        val edges = mapOf(1 to (36 to 27), 2 to (30 to 22), 3 to (24 to 18), 4 to (18 to 14), 5 to (12 to 9))
        for ((level, edge) in edges) {
            val (engage, keep) = edge
            assertEquals("level $level", 0, Joystick.keys(engage - 1, 0, t, 0, level))
            assertEquals("level $level", R, Joystick.keys(engage, 0, t, 0, level))
            assertEquals("level $level", R, Joystick.keys(keep, 0, t, R, level))
            assertEquals("level $level", 0, Joystick.keys(keep - 1, 0, t, R, level))
        }
        assertEquals(3, Joystick.SENSITIVITY_DEFAULT)
        assertEquals("the default needs twice the push of the highest level", 2 * Joystick.engagePercent(Joystick.SENSITIVITY_MAX), Joystick.engagePercent(Joystick.SENSITIVITY_DEFAULT))
        for (push in 0..45) assertEquals("no level given: the default", Joystick.keys(push, 0, t, 0, 3), Joystick.keys(push, 0, t, 0))
        assertEquals("above the levels: the highest", R, Joystick.keys(12, 0, t, 0, 9))
        assertEquals("below them: the lowest", 0, Joystick.keys(35, 0, t, 0, 0))
        assertEquals("the direction is the push's at every level", U or L, Joystick.keys(-40, -40, t, 0, 1))
    }

    // ------------------------------------------------------------ GameControls

    private val area = Rect(0, 300, 360, 200)
    private lateinit var shell: Shell
    private lateinit var dir: File

    @Before fun setUp() {
        dir = kotlin.io.path.createTempDirectory("joy").toFile()
        shell = Shell(HeadlessEnv(dir))
        L10n.use("en-US")
    }

    @After fun tearDown() { dir.deleteRecursively() }

    /** Controls in [area] that record what they send as "<key> down|up", and the mode the toggle asks for. */
    private class Rig(val s: Surface, val area: Rect) {
        private val log = ArrayList<String>()
        val gc = GameControls { e -> if (e is KInput.Key) log.add("${name((e.sc and 0x7F).toInt())} ${if (e.down) "down" else "up"}") }
        var directional = DirectionalControl.DPAD
        var showDpad = true
        var sensitivity = Joystick.SENSITIVITY_DEFAULT
        init { gc.onDirectional = { directional = it }; gc.stickSensitivity = { sensitivity } }
        /** What was sent since the last take. */
        fun take(): List<String> = log.toList().also { log.clear() }
        fun draw() = gc.draw(s, area, emptyList(), vertical = true, showDpad = showDpad, directional = directional)
        fun nodes(): List<Pair<Rect, String>> { val n = ArrayList<Pair<Rect, String>>(); gc.accessibility { r, l, _ -> n.add(r to l) }; return n }
        fun node(label: String) = nodes().firstOrNull { it.second == label }?.first
        fun tap(label: String, id: Int = 9) {
            val r = node(label)!!
            gc.pointer(PointerEvent(Ptr.DOWN, r.x + r.w / 2, r.y + r.h / 2, id)); gc.pointer(PointerEvent(Ptr.UP, r.x + r.w / 2, r.y + r.h / 2, id))
            draw()
        }
        /** A finger [id] at ([dx], [dy]) from the joystick's centre. */
        fun stick(action: Int, dx: Int, dy: Int, id: Int = 1) = gc.pointer(PointerEvent(action, gc.joystick.cx + dx, gc.joystick.cy + dy, id))
        companion object {
            fun name(sc: Int) = when (sc) {
                Keys.SC_CURSOR_UP -> "UP"; Keys.SC_CURSOR_DOWN -> "DOWN"; Keys.SC_CURSOR_LEFT -> "LEFT"; Keys.SC_CURSOR_RIGHT -> "RIGHT"
                else -> "sc$sc"
            }
        }
    }

    private fun rig() = Rig(shell.surface, area).also { it.draw() }

    @Test fun theJoystickExistsOnlyWhereTheDpadDoes() {
        val r = rig()
        assertEquals("the d-pad by default", listOf("\u0018", "\u001B", "\u001A", "\u0019"), r.gc.labels.take(4))
        assertEquals("the switch names the mode it switches to", "JOYSTICK", r.gc.labels.last())
        assertNotNull(r.node("Switch to the joystick"))
        assertFalse(r.gc.joystick.shown)
        r.directional = DirectionalControl.JOYSTICK; r.draw()
        assertFalse("the joystick replaces the four buttons", "\u0018" in r.gc.labels)
        assertTrue(r.gc.joystick.shown)
        assertEquals("D-PAD", r.gc.labels.last())
        assertNotNull(r.node("Joystick: drag to move"))
        assertNotNull(r.node("Switch to the arrow buttons"))
        // the joystick takes the d-pad's square, and the buttons beside it keep their places
        val pad = Rect(area.x + 4, area.y + 4, 132, 132)
        val j = r.gc.joystick.rect
        assertTrue("$j", j.x >= pad.x && j.right <= pad.right && j.bottom <= pad.bottom)
        val stickNodes = r.nodes().filter { it.second != "Joystick: drag to move" }.map { it.first }
        r.directional = DirectionalControl.DPAD; r.draw()
        val padNodes = r.nodes().drop(4).map { it.first }
        assertEquals("SPACE, ENTER, ESC, the touch mode and the switch stay where they were", padNodes, stickNodes)
        // no d-pad: no joystick and no switch, whatever the setting says
        for (mode in DirectionalControl.values()) {
            r.showDpad = false; r.directional = mode; r.draw()
            assertFalse(r.gc.joystick.shown)
            assertNull(r.node("Switch to the joystick")); assertNull(r.node("Switch to the arrow buttons")); assertNull(r.node("Joystick: drag to move"))
            assertEquals(listOf("SPACE", "ENTER", "ESC", "L-CLICK"), r.gc.labels)
        }
    }

    @Test fun theSwitchIsTheAppsAndNeverReachesTheProgram() {
        val r = rig()
        repeat(3) {
            r.tap("Switch to the joystick")
            assertEquals(DirectionalControl.JOYSTICK, r.directional)
            assertEquals("one switch, no duplicate controls", 1, r.gc.labels.count { it == "D-PAD" })
            r.tap("Switch to the arrow buttons")
            assertEquals(DirectionalControl.DPAD, r.directional)
            assertEquals(4, r.gc.labels.count { it in listOf("\u0018", "\u0019", "\u001A", "\u001B") })
        }
        assertEquals("switching sends no key", emptyList<String>(), r.take())
        assertFalse(r.gc.anyHeld)
    }

    @Test fun aPushHoldsArrowsAndSendsOnlyWhatChanges() {
        val r = rig(); r.directional = DirectionalControl.JOYSTICK; r.draw()
        assertTrue(r.stick(Ptr.DOWN, 0, 3)); assertEquals("a touch in the dead zone holds nothing", emptyList<String>(), r.take())
        assertTrue(r.stick(Ptr.MOVE, 0, -30)); assertEquals(listOf("UP down"), r.take())
        assertTrue(r.stick(Ptr.MOVE, 2, -34)); assertEquals("a wobble inside the same direction sends nothing", emptyList<String>(), r.take())
        assertTrue(r.stick(Ptr.MOVE, 25, -25)); assertEquals("up stays down on the diagonal", listOf("RIGHT down"), r.take())
        assertTrue(r.stick(Ptr.MOVE, 30, 0)); assertEquals(listOf("UP up"), r.take())
        assertTrue(r.stick(Ptr.MOVE, 300, 280)); assertEquals("far outside the joystick it still steers", listOf("DOWN down"), r.take())
        val j = r.gc.joystick
        assertTrue("the knob stays inside", j.knobX * j.knobX + j.knobY * j.knobY <= (j.travel + 1) * (j.travel + 1))
        assertTrue(r.stick(Ptr.MOVE, 0, 30)); assertEquals(listOf("RIGHT up"), r.take())
        assertTrue(r.stick(Ptr.MOVE, -30, 0)); assertEquals("a jump across releases first", listOf("DOWN up", "LEFT down"), r.take())
        assertTrue(r.stick(Ptr.MOVE, -4, 0)); assertEquals("back to the centre: nothing held", listOf("LEFT up"), r.take())
        assertTrue(r.stick(Ptr.MOVE, -30, 0)); assertEquals(listOf("LEFT down"), r.take())
        assertTrue(r.stick(Ptr.UP, -30, 0)); assertEquals(listOf("LEFT up"), r.take())
        assertFalse(r.gc.anyHeld)
        assertTrue(r.stick(Ptr.DOWN, 40, 0)); assertEquals("a touch away from the centre pushes at once", listOf("RIGHT down"), r.take())
        assertTrue(r.stick(Ptr.CANCEL, 40, 0)); assertEquals("a cancelled touch releases too", listOf("RIGHT up"), r.take())
    }

    /** The setting is read at each push: the same finger holds its arrow sooner or later with the level. */
    @Test fun thePushThatHoldsFollowsTheSensitivity() {
        val r = rig(); r.directional = DirectionalControl.JOYSTICK; r.draw()
        fun at(percent: Int) = r.gc.joystick.travel * percent / 100
        assertTrue(r.stick(Ptr.DOWN, at(50), 0)); assertEquals("the default: half the travel holds nothing", emptyList<String>(), r.take())
        assertTrue(r.stick(Ptr.MOVE, at(70), 0)); assertEquals(listOf("RIGHT down"), r.take())
        assertTrue(r.stick(Ptr.UP, at(70), 0)); assertEquals(listOf("RIGHT up"), r.take())
        r.sensitivity = Joystick.SENSITIVITY_MAX
        assertTrue(r.stick(Ptr.DOWN, at(40), 0)); assertEquals("the highest level holds from a short push", listOf("RIGHT down"), r.take())
        assertTrue(r.stick(Ptr.UP, at(40), 0)); assertEquals(listOf("RIGHT up"), r.take())
        r.sensitivity = Joystick.SENSITIVITY_MIN
        assertTrue(r.stick(Ptr.DOWN, at(80), 0)); assertEquals("the lowest needs nearly the whole travel", emptyList<String>(), r.take())
        assertTrue(r.stick(Ptr.MOVE, at(95), 0)); assertEquals(listOf("RIGHT down"), r.take())
        assertTrue(r.stick(Ptr.MOVE, at(70), 0)); assertEquals("held a little inside the edge", emptyList<String>(), r.take())
        assertTrue(r.stick(Ptr.MOVE, at(50), 0)); assertEquals(listOf("RIGHT up"), r.take())
        assertTrue(r.stick(Ptr.UP, at(50), 0)); assertEquals(emptyList<String>(), r.take())
        assertFalse(r.gc.anyHeld)
    }

    /** A held push repeats like a held d-pad button (TempleOS KbdTypeMatic(0): 250 ms, then 30/s). */
    @Test fun aHeldPushRepeatsLikeTheDpad() {
        val r = rig(); r.directional = DirectionalControl.JOYSTICK; r.draw()
        r.stick(Ptr.DOWN, 30, 0)
        val log = r.take().toMutableList()
        r.gc.tick(1000); r.gc.tick(1200); log += r.take()
        assertEquals("no repeat before 250 ms", listOf("RIGHT down"), log)
        r.gc.tick(1260); assertEquals("first repeat after 250 ms", listOf("RIGHT down"), r.take())
        for (t in 1293..2260 step 33) r.gc.tick(t.toLong())
        val n = r.take().size
        assertTrue("about 30 repeats per second: $n", n in 28..34)
        r.stick(Ptr.MOVE, 25, -25); assertEquals(listOf("UP down"), r.take())
        for (t in 2293..2800 step 33) r.gc.tick(t.toLong())
        assertTrue("the arrow pressed last repeats, as on a PC keyboard", r.take().all { it == "UP down" })
        r.stick(Ptr.UP, 25, -25); assertEquals(listOf("UP up", "RIGHT up"), r.take())
        r.gc.tick(4000); r.gc.tick(5000)
        assertEquals("nothing repeats after the release", emptyList<String>(), r.take())
    }

    @Test fun theJoystickAndButtonsAreSeparateFingers() {
        val r = rig(); r.directional = DirectionalControl.JOYSTICK; r.draw()
        val space = r.node("Space")!!
        r.stick(Ptr.DOWN, 0, -30, id = 1); assertEquals(listOf("UP down"), r.take())
        r.gc.pointer(PointerEvent(Ptr.DOWN, space.x + 4, space.y + 4, 2)); assertEquals("SPACE with the joystick held", listOf("sc57 down"), r.take())
        assertTrue("a second finger on the joystick is taken", r.stick(Ptr.DOWN, 30, 0, id = 3))
        r.stick(Ptr.MOVE, 30, 0, id = 3); assertEquals("and ignored", emptyList<String>(), r.take())
        assertEquals("it does not move the knob", 0, r.gc.joystick.knobX)
        r.stick(Ptr.UP, 30, 0, id = 3); assertEquals(emptyList<String>(), r.take())
        r.gc.pointer(PointerEvent(Ptr.UP, space.x + 4, space.y + 4, 2)); assertEquals("SPACE goes up alone", listOf("sc57 up"), r.take())
        r.stick(Ptr.MOVE, 30, 0, id = 1); assertEquals("the joystick still steers", listOf("UP up", "RIGHT down"), r.take())
        r.gc.pointer(PointerEvent(Ptr.DOWN, space.x + 4, space.y + 4, 2)); r.take()
        r.stick(Ptr.UP, 30, 0, id = 1); assertEquals("the joystick lets go alone", listOf("RIGHT up"), r.take())
        assertTrue("SPACE is still held", r.gc.anyHeld)
        r.gc.pointer(PointerEvent(Ptr.UP, space.x + 4, space.y + 4, 2)); assertEquals(listOf("sc57 up"), r.take())
    }

    @Test fun switchingReleasesTheArrowsAndNothingElse() {
        val r = rig(); r.directional = DirectionalControl.JOYSTICK; r.draw()
        val space = r.node("Space")!!
        r.gc.pointer(PointerEvent(Ptr.DOWN, space.x + 4, space.y + 4, 2))
        r.stick(Ptr.DOWN, 30, 0, id = 1); r.take()
        r.tap("Switch to the arrow buttons")
        assertEquals("the joystick's arrow goes up with the joystick", listOf("RIGHT up"), r.take())
        assertEquals(DirectionalControl.DPAD, r.directional)
        r.stick(Ptr.MOVE, 0, 30, id = 1); r.stick(Ptr.UP, 0, 30, id = 1)
        assertEquals("its finger holds nothing more", emptyList<String>(), r.take())
        // and back: a finger on a d-pad button lets go of its arrow too
        val up = r.node("Up arrow")!!
        r.gc.pointer(PointerEvent(Ptr.DOWN, up.x + 4, up.y + 4, 4)); assertEquals(listOf("UP down"), r.take())
        r.tap("Switch to the joystick")
        assertEquals(listOf("UP up"), r.take())
        r.gc.pointer(PointerEvent(Ptr.UP, up.x + 4, up.y + 4, 4)); assertEquals(emptyList<String>(), r.take())
        assertTrue("SPACE stays held through both switches", r.gc.anyHeld)
        r.gc.pointer(PointerEvent(Ptr.UP, space.x + 4, space.y + 4, 2)); assertEquals(listOf("sc57 up"), r.take())
    }

    @Test fun nothingTheJoystickHoldsOutlivesIt() {
        val r = rig(); r.directional = DirectionalControl.JOYSTICK; r.draw()
        fun hold() { r.stick(Ptr.DOWN, 0, 30); assertEquals(listOf("DOWN down"), r.take()) }
        fun lifted(why: String) { r.stick(Ptr.MOVE, 30, 0); r.stick(Ptr.UP, 30, 0); assertEquals("$why: the finger holds nothing more", emptyList<String>(), r.take()) }
        hold(); r.showDpad = false; r.draw(); assertEquals("the program has no d-pad", listOf("DOWN up"), r.take()); lifted("no d-pad")
        r.showDpad = true; r.draw()
        hold(); r.gc.clearLayout(); assertEquals("no control area", listOf("DOWN up"), r.take()); lifted("no control area")
        r.draw()
        hold(); r.gc.draw(r.s, Rect(0, 200, 360, 200), emptyList(), vertical = true, showDpad = true, directional = DirectionalControl.JOYSTICK)
        assertEquals("the joystick moved under the finger (rotation)", listOf("DOWN up"), r.take()); lifted("moved")
        r.draw()
        hold(); r.gc.draw(r.s, Rect(0, 0, 30, 30), emptyList(), vertical = true, showDpad = true, directional = DirectionalControl.JOYSTICK)
        assertEquals("too small for controls", listOf("DOWN up"), r.take()); lifted("too small")
        r.draw()
        hold(); r.gc.releaseAll(); assertEquals("focus loss, background, pause, stop", listOf("DOWN up"), r.take()); lifted("released")
        r.draw(); hold(); r.stick(Ptr.MOVE, 0, 32)
        r.draw(); r.draw(); assertEquals("redrawing changes nothing", emptyList<String>(), r.take())
        // the knob eases back after a release; the keys are already up
        r.stick(Ptr.UP, 0, 32); assertEquals(listOf("DOWN up"), r.take())
        assertNotEquals(0, r.gc.joystick.knobY)
        assertTrue(r.gc.tick(10_000)); assertTrue(r.gc.tick(10_040))
        assertTrue(r.gc.tick(10_100)); assertEquals("home after 80 ms", 0, r.gc.joystick.knobY)
        assertFalse("and then nothing to redraw", r.gc.tick(10_116))
    }

    @Test fun theSettingIsKeptAndOldSessionsKeepTheDpad() {
        assertEquals(DirectionalControl.DPAD, Settings().directional)
        assertEquals("a session from before the joystick", DirectionalControl.DPAD, Settings.decode("d=8;s=1;o=2;u=0;c=0;t=0;k=0;g=;e=0").directional)
        val st = Settings(); st.directional = DirectionalControl.JOYSTICK
        assertTrue(st.encode().contains(";j=1;"))
        assertEquals(DirectionalControl.JOYSTICK, Settings.decode(st.encode()).directional)
        assertEquals(DirectionalControl.DPAD, Settings.decode("j=7").directional)
    }

    @Test fun theSensitivityIsKeptAndOldSessionsGetTheDefault() {
        assertEquals(Joystick.SENSITIVITY_DEFAULT, Settings().joystickSensitivity)
        val old = Settings.decode("d=8;s=1;o=2;u=0;c=0;t=0;k=0;g=;e=0;j=1;i=1")
        assertEquals("a session from before the setting", Joystick.SENSITIVITY_DEFAULT, old.joystickSensitivity)
        assertEquals("its other settings stay", DirectionalControl.JOYSTICK, old.directional); assertTrue(old.importIntroSeen)
        val st = Settings(); st.joystickSensitivity = 5; st.directional = DirectionalControl.JOYSTICK
        assertTrue(st.encode(), st.encode().contains(";j=1;js=5;"))
        assertEquals(5, Settings.decode(st.encode()).joystickSensitivity)
        assertEquals(DirectionalControl.JOYSTICK, Settings.decode(st.encode()).directional)
        assertEquals("out of range: the nearest level", 5, Settings.decode("js=9").joystickSensitivity)
        assertEquals(1, Settings.decode("js=0").joystickSensitivity)
        assertEquals("not a number: the default", Joystick.SENSITIVITY_DEFAULT, Settings.decode("js=high").joystickSensitivity)
    }

    /** Settings > Joystick sensitivity: a tap goes to the next level and round again, saved with the session. */
    @Test fun theSettingsRowCyclesThroughTheLevels() {
        val env = HeadlessEnv(dir)
        val sh = Shell(env); sh.resize(360, 640); sh.tick()
        Launch.settings(sh); sh.invalidate(); sh.tick()
        fun row(level: Int) = sh.accessibilityNodes().firstOrNull { it.label == "Joystick sensitivity: $level/5" }?.rect
        fun tap(r: Rect) {
            sh.pointer(PointerEvent(Ptr.DOWN, r.x + r.w / 2, r.y + r.h / 2, 1)); sh.pointer(PointerEvent(Ptr.UP, r.x + r.w / 2, r.y + r.h / 2, 1))
            sh.invalidate(); sh.tick()
        }
        for (next in listOf(4, 5, 1, 2, 3)) {
            val before = sh.settings.joystickSensitivity
            tap(row(before)!!)
            assertEquals(next, sh.settings.joystickSensitivity)
            assertNotNull("the row shows level $next", row(next)); assertNull(row(before))
            assertTrue("saved: ${env.session}", env.session!!.contains(";js=$next;"))
        }
        tap(row(3)!!); tap(row(4)!!)
        val again = Shell(env); again.resize(360, 640); again.restoreSession(); again.tick()
        assertEquals("kept across a relaunch", 5, again.settings.joystickSensitivity)
    }

    // ------------------------------------------------------------ programs, through the shell

    private class Run(val sh: Shell, val p: ProgramApp, val dir: File) {
        val k get() = p.kernel
        /** Where the joystick is (a finger keeps steering it while a menu hides it from the screen reader). */
        private var stickRect: Rect? = null
        fun nodes(): List<A11yNode> { sh.invalidate(); sh.tick(); return sh.accessibilityNodes() }
        fun node(label: String) = nodes().firstOrNull { it.label == label }?.rect
        fun waitFor(ms: Long, c: () -> Boolean): Boolean {
            val end = System.currentTimeMillis() + ms
            while (System.currentTimeMillis() < end) { sh.tick(); if (c()) return true; Thread.sleep(16) }
            sh.tick(); return c()
        }
        fun bit(b: Int): Boolean {
            val a = k.o.kbdAddr + k.o.member("CKbdStateGlbls", "down_bitmap")
            return (k.mem.ld1(a + (b shr 3)) shr (b and 7)) and 1L != 0L
        }
        fun tap(label: String) {
            val r = node(label)!!
            sh.pointer(PointerEvent(Ptr.DOWN, r.x + r.w / 2, r.y + r.h / 2, 50)); sh.pointer(PointerEvent(Ptr.UP, r.x + r.w / 2, r.y + r.h / 2, 50)); sh.tick()
        }
        fun stick(action: Int, dx: Int, dy: Int, id: Int = 1) {
            val r = stickRect ?: node("Joystick: drag to move")!!.also { stickRect = it }
            sh.pointer(PointerEvent(action, r.x + r.w / 2 + dx, r.y + r.h / 2 + dy, id)); sh.tick()
        }
        fun close() { sh.windows.toList().forEach { sh.close(it, force = true) }; dir.deleteRecursively() }
    }

    private fun launch(path: String, directional: DirectionalControl = DirectionalControl.DPAD, popupOk: Boolean = false): Run {
        val dir = kotlin.io.path.createTempDirectory("joyrun").toFile()
        val sh = Shell(HeadlessEnv(dir)); sh.resize(360, 640); sh.tick()
        sh.settings.directional = directional
        Launch.program(sh, path, sh.catalog.byPath(path))
        val r = Run(sh, sh.focused!!.app as ProgramApp, dir)
        if (popupOk) { assertTrue("$path popup", r.waitFor(30_000) { sh.dialogOpen }); sh.key('\n'.code, Keys.forChar('\n'.code).second, true) }
        assertTrue("$path runs", r.waitFor(30_000) { r.k.graphicsUsed && r.k.frameCount >= 10 })
        return r
    }

    /** Halogen holds its arrows down (Bt(kbd.down_bitmap)): the joystick holds them, beside SPACE, and lets them go. */
    @Test fun theJoystickDrivesAProgramThroughTheShell() {
        val r = launch("C:/Demo/Games/Halogen.HC")
        try {
            assertNotNull(r.node("Up arrow"))
            val kernel = r.k; val frames = r.k.frameCount
            r.tap("Switch to the joystick")
            assertEquals("the choice is the user's setting", DirectionalControl.JOYSTICK, r.sh.settings.directional)
            assertNull(r.node("Up arrow")); assertNotNull(r.node("Switch to the arrow buttons"))
            assertTrue("the program kept running", r.waitFor(2000) { r.k.frameCount > frames + 5 })
            assertTrue("the same program, not restarted", r.p.kernel === kernel && !r.p.isFinished)
            r.stick(Ptr.DOWN, 0, -40)
            assertTrue("up is held", r.waitFor(1000) { r.bit(Keys.SC_CURSOR_UP) })
            val space = r.node("Space")!!
            r.sh.pointer(PointerEvent(Ptr.DOWN, space.x + 4, space.y + 4, 2)); r.sh.tick()
            assertTrue("SPACE with the joystick", r.waitFor(1000) { r.bit(Keys.SC_SPACE) && r.bit(Keys.SC_CURSOR_UP) })
            r.stick(Ptr.MOVE, 40, -40)
            assertTrue("a diagonal holds two arrows", r.waitFor(1000) { r.bit(Keys.SC_CURSOR_UP) && r.bit(Keys.SC_CURSOR_RIGHT) })
            r.sh.pointer(PointerEvent(Ptr.UP, space.x + 4, space.y + 4, 2)); r.sh.tick()
            assertTrue("SPACE goes up alone", r.waitFor(1000) { !r.bit(Keys.SC_SPACE) && r.bit(Keys.SC_CURSOR_RIGHT) })
            r.stick(Ptr.UP, 40, -40)
            assertTrue("released with the finger", r.waitFor(1000) { !r.bit(Keys.SC_CURSOR_UP) && !r.bit(Keys.SC_CURSOR_RIGHT) })
            // a menu takes the input: a held push is let go
            r.stick(Ptr.DOWN, -40, 0)
            assertTrue(r.waitFor(1000) { r.bit(Keys.SC_CURSOR_LEFT) })
            r.sh.showMenu(listOf(MenuItem("x") {}), 0, 0)
            assertTrue("a menu releases the joystick", r.waitFor(1000) { !r.bit(Keys.SC_CURSOR_LEFT) })
            r.stick(Ptr.UP, -40, 0); r.sh.back()
            r.tap("Switch to the arrow buttons")
            assertEquals(DirectionalControl.DPAD, r.sh.settings.directional)
            assertNotNull(r.node("Up arrow")); assertNull(r.node("Joystick: drag to move"))
            val up = r.node("Up arrow")!!
            r.sh.pointer(PointerEvent(Ptr.DOWN, up.x + 4, up.y + 4, 3)); r.sh.tick()
            assertTrue("the d-pad works again", r.waitFor(1000) { r.bit(Keys.SC_CURSOR_UP) })
            r.sh.pointer(PointerEvent(Ptr.UP, up.x + 4, up.y + 4, 3)); r.sh.tick()
            assertTrue(r.waitFor(1000) { !r.bit(Keys.SC_CURSOR_UP) })
            assertEquals(DirectionalControl.DPAD, Settings.decode(r.sh.settings.encode()).directional)
        } finally { r.close() }
    }

    /** A running program's joystick follows the setting from its next push on (Halogen holds its arrows down). */
    @Test fun aRunningProgramFollowsTheSensitivity() {
        val r = launch("C:/Demo/Games/Halogen.HC", DirectionalControl.JOYSTICK)
        try {
            assertEquals(Joystick.SENSITIVITY_DEFAULT, r.sh.settings.joystickSensitivity)
            r.stick(Ptr.DOWN, 0, -15)
            assertFalse("the default: a short push holds nothing", r.waitFor(300) { r.bit(Keys.SC_CURSOR_UP) })
            r.stick(Ptr.MOVE, 0, -28)
            assertTrue("a longer one holds up", r.waitFor(1000) { r.bit(Keys.SC_CURSOR_UP) })
            r.stick(Ptr.UP, 0, -28)
            assertTrue(r.waitFor(1000) { !r.bit(Keys.SC_CURSOR_UP) })
            r.sh.settings.joystickSensitivity = Joystick.SENSITIVITY_MAX
            r.stick(Ptr.DOWN, 0, -15)
            assertTrue("the highest level: the short push holds up", r.waitFor(1000) { r.bit(Keys.SC_CURSOR_UP) })
            r.stick(Ptr.UP, 0, -15)
            assertTrue(r.waitFor(1000) { !r.bit(Keys.SC_CURSOR_UP) })
            r.sh.settings.joystickSensitivity = Joystick.SENSITIVITY_MIN
            r.stick(Ptr.DOWN, 0, -28)
            assertFalse("the lowest level: the longer push holds nothing", r.waitFor(300) { r.bit(Keys.SC_CURSOR_UP) })
            r.stick(Ptr.MOVE, 0, -40)
            assertTrue("the whole travel does", r.waitFor(1000) { r.bit(Keys.SC_CURSOR_UP) })
            r.stick(Ptr.UP, 0, -40)
            assertTrue(r.waitFor(1000) { !r.bit(Keys.SC_CURSOR_UP) })
        } finally { r.close() }
    }

    /** Android keeps its back gesture out of the joystick: the shell reports its square while it is on screen and focused. */
    @Test fun theSystemEdgeGesturesStayOutOfTheJoystick() {
        val r = launch("C:/Demo/Games/Halogen.HC", DirectionalControl.JOYSTICK)
        try {
            val stick = r.node("Joystick: drag to move")!!
            assertEquals(listOf(stick), r.sh.systemChrome.gestureExclusion)
            r.sh.showMenu(listOf(MenuItem("x") {}), 0, 0); r.sh.tick()
            assertEquals("a menu takes the touches", emptyList<Rect>(), r.sh.systemChrome.gestureExclusion)
            r.sh.back(); r.sh.invalidate(); r.sh.tick()
            assertEquals(listOf(stick), r.sh.systemChrome.gestureExclusion)
            r.tap("Switch to the arrow buttons"); r.sh.invalidate(); r.sh.tick()
            assertEquals("the d-pad's buttons are tapped, not dragged", emptyList<Rect>(), r.sh.systemChrome.gestureExclusion)
        } finally { r.close() }
    }

    /** CastleFrankenstein walks one step per key message: a held push walks it like a held d-pad button. */
    @Test fun aHeldPushWalksCastleFrankenstein() {
        val r = launch("C:/Demo/Games/CastleFrankenstein.HC", DirectionalControl.JOYSTICK)
        try {
            fun g(n: String) = r.k.mem.ld8((r.k.prog.globals[n] as GlobalSym).addr)
            assertTrue(r.waitFor(30_000) { r.k.frameCount >= 20 })
            val x0 = g("man_xx"); val y0 = g("man_yy")
            r.stick(Ptr.DOWN, 0, -45)
            val t0 = System.currentTimeMillis()
            while (System.currentTimeMillis() - t0 < 2000) { r.sh.tick(); Thread.sleep(16) }
            r.stick(Ptr.UP, 0, -45)
            Thread.sleep(300); r.sh.tick()
            assertTrue("the player walked", Math.abs(g("man_xx") - x0) + Math.abs(g("man_yy") - y0) > 1000)
            assertFalse(r.bit(Keys.SC_CURSOR_UP))
        } finally { r.close() }
    }

    /** FlapBat has no d-pad: it never gets the joystick or its switch, even when the user chose the joystick. */
    @Test fun aProgramWithoutTheDpadNeverGetsTheJoystick() {
        val r = launch("C:/Demo/Games/FlapBat.HC", DirectionalControl.JOYSTICK, popupOk = true)
        try {
            val labels = r.nodes().map { it.label }
            assertTrue("$labels", "Space" in labels)
            for (l in listOf("Joystick: drag to move", "Switch to the joystick", "Switch to the arrow buttons", "Up arrow")) assertFalse(l, l in labels)
            assertEquals(emptyList<Rect>(), r.sh.systemChrome.gestureExclusion)
        } finally { r.close() }
    }
}
