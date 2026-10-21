package com.example.mactv_androidapp

import com.example.mactv_androidapp.connection.AppContext
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AppContextTest {
    @Test fun readsCapabilitiesWithoutTrustingThemAsExecutableCommands() {
        val context = AppContext.parse(JSONObject("""{"app":"player","title":"A movie","keys":["subtitles","restart","unrecognized"],"foreground":false,"subtitle":"English"}"""))
        assertEquals("player", context.app)
        assertFalse(context.foreground)
        assertEquals("English", context.subtitle)
        assertTrue("subtitles" in context.keys)
    }
    @Test fun acceptsSportsContexts() {
        listOf("f1", "football").forEach { app ->
            assertEquals(app, AppContext.parse(JSONObject().put("app", app).put("title", "Sports")).app)
        }
    }
    @Test(expected = IllegalArgumentException::class) fun rejectsUnknownContext() {
        AppContext.parse(JSONObject("""{"app":"/bin/sh"}"""))
    }
}
