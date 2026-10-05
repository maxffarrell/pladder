import Testing
@testable import PladderCore

@Test func waitsForAgreementAndWithholdsTrailingWord() {
    var transcript = StableTranscript()
    #expect(transcript.observe("We can sail", revision: 1).isEmpty)
    #expect(transcript.observe("We can sell tomorrow", revision: 2) == "We can")
    #expect(transcript.observe("We can sell tomorrow", revision: 2) == "We can")
    #expect(transcript.observe("We can sell tomorrow morning", revision: 3) == "We can sell tomorrow")
}

@Test func revealedWordsAreNeverRewritten() {
    var transcript = StableTranscript()
    transcript.observe("Hello world today", revision: 1)
    #expect(transcript.observe("Hello world today again", revision: 2) == "Hello world today")
    #expect(transcript.observe("Hallo world", revision: 3) == "Hello world today")
    #expect(transcript.observe("", revision: 4) == "Hello world today")
}

@Test func preservesUnicodeAndPunctuation() {
    var transcript = StableTranscript()
    transcript.observe("Café, très bien!", revision: 1)
    #expect(transcript.observe("Café, très bien! Merci.", revision: 2) == "Café, très bien!")
}
