package com.luverse.morit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BackendTransferValidationTest {
    @Test
    fun opaqueStatusUrlAndJobIdAreAccepted() {
        val jobId = requireBackendTransferJobId("0123456789abcdef0123456789abcdef")
        val uri = requireBackendTransferStatusUri(
            "https://download.example.com/v1/transfers/$jobId" +
                "?ticket=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ",
        )

        assertEquals("download.example.com", uri.host)
        assertEquals(jobId, requireBackendTransferJobId(jobId))
    }

    @Test(expected = IllegalArgumentException::class)
    fun statusUrlWithout256BitTicketIsRejected() {
        requireBackendTransferStatusUri(
            "https://download.example.com/v1/transfers/job?ticket=short",
        )
    }

    @Test
    fun schedulerIdsAreStableAndSalted() {
        val jobId = "0123456789abcdef0123456789abcdef"

        assertEquals(
            backendTransferSchedulerId(jobId),
            backendTransferSchedulerId(jobId),
        )
        assertNotEquals(
            backendTransferSchedulerId(jobId),
            backendTransferSchedulerId(jobId, 1),
        )
    }

    @Test
    fun unknownContentLengthDoesNotBlockDeviceHandoff() {
        assertEquals(null, optionalBackendContentLength(-1))
        assertEquals(null, optionalBackendContentLength(0))
        assertEquals(42L, optionalBackendContentLength(42))
    }

    @Test
    fun fileNameIsLeafOnlyBoundedAndJobScoped() {
        val fileName = backendTransferFileName(
            "0123456789abcdef0123456789abcdef",
            "../unsafe:${"x".repeat(240)}.mp4",
        )

        assertTrue(fileName.startsWith("0123456789ab_"))
        assertTrue(fileName.endsWith(".mp4"))
        assertTrue(fileName.length <= 200)
        assertTrue('/' !in fileName && '\\' !in fileName && ':' !in fileName)
    }

    @Test
    fun publicErrorKeepsDiagnosticsAndRedactsSecrets() {
        val message = formatBackendPublicError(
            message = "Extractor failed at https://example.com/private?" +
                "ticket=abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ",
            platform = "instagram",
            engine = "yt-dlp",
            code = "MEDIA_UNAVAILABLE",
            logId = "abc123def456",
        ).orEmpty()

        assertTrue("[link]" in message)
        assertTrue("platform=instagram" in message)
        assertTrue("engine=yt-dlp" in message)
        assertTrue("code=MEDIA_UNAVAILABLE" in message)
        assertTrue("log_id=abc123def456" in message)
        assertTrue("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ" !in message)
    }
}
