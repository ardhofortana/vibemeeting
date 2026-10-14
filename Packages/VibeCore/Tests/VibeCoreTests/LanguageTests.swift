import XCTest
@testable import VibeCore

/// One call language per meeting; replies, questions and the recap follow it
/// unless the user picked another language for them.
final class LanguageTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func meeting(_ language: MeetingLanguage) -> MeetingPromptContext {
        MeetingPromptContext(aboutMe: "Name: Sam Rivera", context: [.text("Plan: two milestones.")], preset: .friendlyPro, meetingInstructions: "", goal: "Agree on next steps.", language: language)
    }

    func ask(_ text: String = "Wann können wir starten?") -> ReplyAsk {
        let turn = TranscriptTurn(speaker: .them, finalText: text, startedAt: t0)
        return ReplyAsk(target: ReplyTarget(turnIDs: [turn.id], speaker: .them, text: text, isLive: false), recentTurns: [turn])
    }

    // MARK: - The model

    func testScriptAndRecapFollowTheCallUnlessOverridden() {
        let german = MeetingLanguage(callLocale: "de-DE")
        XCTAssertEqual(german.script, "de-DE")
        XCTAssertEqual(german.recap, "de-DE")
        XCTAssertFalse(german.isEnglishCall)

        let overridden = MeetingLanguage(callLocale: "de-DE", scriptLanguage: "en-GB", recapLanguage: "id")
        XCTAssertEqual(overridden.script, "en-GB")
        XCTAssertEqual(overridden.recap, "id")

        XCTAssertEqual(MeetingLanguage.english, MeetingLanguage(callLocale: "en-US"))
        XCTAssertTrue(MeetingLanguage.english.isEnglishCall)
        XCTAssertTrue(MeetingLanguage.isEnglish("en-GB"))
        XCTAssertFalse(MeetingLanguage.isEnglish("es-ES"))
    }

    func testNamesAndIdentifiers() {
        XCTAssertEqual(MeetingLanguage.normalized("en_US"), "en-US")
        XCTAssertEqual(MeetingLanguage.languageCode(of: "pt-BR"), "pt")
        XCTAssertEqual(MeetingLanguage.englishName(of: "de-DE"), "German (Germany)")
        XCTAssertEqual(MeetingLanguage.englishName(of: "en-US"), "English (United States)")
        XCTAssertEqual(ReplyPromptBuilder.describe("de-DE"), "German (Germany), de-DE")
    }

    func testLanguagesOutsideLatinAndCyrillicAreAPreview() {
        for identifier in ["ja-JP", "zh-CN", "zh-TW", "yue-CN", "ko-KR", "th-TH", "ar-SA", "he-IL"] {
            XCTAssertTrue(MeetingLanguage.isPreview(identifier), identifier)
        }
        for identifier in ["en-US", "de-DE", "fr-CA", "pt-BR", "es-MX", "ru-RU", "uk-UA", "vi-VN", "id"] {
            XCTAssertFalse(MeetingLanguage.isPreview(identifier), identifier)
        }
    }

    func testDefaultCallLanguageIsEnglishInThePreferredVariant() {
        let supported = ["en-US", "en-GB", "en-IN", "de-DE", "fr-FR", "fr-CA", "es-ES", "pt-BR", "ja-JP", "zh-CN", "id-ID", "ms-MY"]
        func pick(_ preferred: [String]) -> String {
            MeetingLanguage.defaultCallLocale(preferredLanguages: preferred, supported: supported)
        }
        // Other languages, even supported ones, are never the default.
        XCTAssertEqual(pick(["de-DE", "en-US"]), "en-US")
        XCTAssertEqual(pick(["de-DE", "en-GB"]), "en-GB")
        XCTAssertEqual(pick(["id-ID"]), "en-US")
        XCTAssertEqual(pick(["id-ID", "ms-MY", "en-IN"]), "en-IN")
        XCTAssertEqual(pick(["fr-CA", "de-DE"]), "en-US")
        XCTAssertEqual(pick([]), "en-US")
        // English in another region: the usual form.
        XCTAssertEqual(pick(["en-ID", "id-ID"]), "en-US")
        XCTAssertEqual(pick(["en-AU"]), "en-US")
        XCTAssertEqual(pick(["en"]), "en-US")
        XCTAssertEqual(MeetingLanguage.defaultCallLocale(preferredLanguages: ["en_GB"], supported: ["en_GB", "en_US"]), "en-GB")
        XCTAssertEqual(MeetingLanguage.defaultCallLocale(preferredLanguages: ["en-GB"], supported: []), "en-US")
    }

    func testCallLanguagesAddWhatOnlyDictationHears() {
        let locales = CallLocales(
            speech: ["en-US", "en-GB", "de-DE", "en-US"],
            dictation: ["en_US", "de-DE", "de-AT", "id-ID", "ms-MY", "id-ID"],
            speechEquivalents: ["de-AT": "de-DE", "id-ID": "en-US", "ms-MY": "ms-MY"]
        )
        // Each language once; one the speech model takes under another identifier
        // isn't added. An "equivalent" in another language, or one the speech
        // model doesn't list (as macOS 26.6.2 answers for Indonesian), never counts.
        XCTAssertEqual(locales.all, ["en-US", "en-GB", "de-DE", "id-ID", "ms-MY"])
        XCTAssertEqual(locales.speech, ["en-US", "en-GB", "de-DE"])
        XCTAssertEqual(locales.dictationOnly, ["id-ID", "ms-MY"])
        XCTAssertEqual(locales.ignoredEquivalents, ["id-ID": "en-US", "ms-MY": "ms-MY"])

        // What the owner's Mac answered: an equivalent for every Dictation-only
        // language, each the locale itself.
        let speech26 = ["en-US", "de-DE", "zh-CN"]
        let dictation26 = ["en-US", "de-DE", "zh-CN", "id-ID", "ms-MY", "ar-SA"]
        let answers = Dictionary(uniqueKeysWithValues: ["id-ID", "ms-MY", "ar-SA"].map { ($0, $0) })
        XCTAssertEqual(CallLocales(speech: speech26, dictation: dictation26, speechEquivalents: answers).dictationOnly, ["id-ID", "ms-MY", "ar-SA"])

        XCTAssertTrue(MeetingLanguage.isSameLanguage("de-AT", "de_DE"))
        XCTAssertFalse(MeetingLanguage.isSameLanguage("id-ID", "en-US"))
        XCTAssertFalse(MeetingLanguage.isSameLanguage("", "en-US"))
        XCTAssertEqual(MeetingLanguage.entry(for: "en_US", in: ["en-GB", "en-US"]), "en-US")
        XCTAssertEqual(MeetingLanguage.entry(for: "zh-Hans-CN", in: ["zh-CN", "zh-TW"]), "zh-CN")
        XCTAssertNil(MeetingLanguage.entry(for: "id-ID", in: ["en-US", "ms-MY"]))
        XCTAssertNil(MeetingLanguage.entry(for: "de-AT", in: ["de-DE"]))

        // Automatic stays on the speech model: an English only Dictation has
        // (such as English (Indonesia)) gives the usual form.
        let english = CallLocales(speech: ["en-US", "en-GB"], dictation: ["en-US", "en-ID", "id-ID"])
        XCTAssertEqual(english.dictationOnly, ["en-ID", "id-ID"])
        XCTAssertEqual(MeetingLanguage.defaultCallLocale(preferredLanguages: ["en-ID", "id-ID"], supported: english.speech), "en-US")

        // A language counts as installed only with the model that hears it.
        XCTAssertEqual(locales.installed(speech: ["en-US", "id-ID"], dictation: ["en-GB", "ms-MY"]), ["en-US", "ms-MY"])
        XCTAssertEqual(locales.installed(speech: [], dictation: []), [])

        // Without the speech model, Dictation hears every language.
        let dictation = CallLocales(speech: [], dictation: ["en-US", "id-ID"])
        XCTAssertEqual(dictation.all, ["en-US", "id-ID"])
        XCTAssertEqual(dictation.speech, [])
        XCTAssertEqual(dictation.dictationOnly, ["en-US", "id-ID"])
        XCTAssertEqual(dictation.installed(speech: ["en-US"], dictation: ["id-ID"]), ["id-ID"])
        // Automatic then picks from Dictation's English variants.
        let britishDictation = CallLocales(speech: [], dictation: ["en-US", "en-GB", "id-ID"])
        XCTAssertEqual(MeetingLanguage.defaultCallLocale(preferredLanguages: ["en-GB"], supported: britishDictation.all), "en-GB")
    }

    func testWritingLanguagesHaveNames() {
        XCTAssertEqual(Set(MeetingLanguage.writingLanguages).count, MeetingLanguage.writingLanguages.count)
        for identifier in MeetingLanguage.writingLanguages {
            XCTAssertEqual(MeetingLanguage.normalized(identifier), identifier)
            XCTAssertNotEqual(MeetingLanguage.englishName(of: identifier), identifier, identifier)
        }
    }

    // MARK: - Saved meetings

    func testOldMeetingsLoadAsEnglish() throws {
        let record = MeetingRecord(name: "Old", presetID: "p", presetName: "P", language: MeetingLanguage(callLocale: "de-DE"), replyModel: "m")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        XCTAssertEqual((json["language"] as? [String: Any])?["callLocale"] as? String, "de-DE")
        json.removeValue(forKey: "language")
        json.removeValue(forKey: "schemaVersion")
        let old = try JSONDecoder().decode(MeetingRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.language, .english)
        XCTAssertEqual(old.schemaVersion, 1)
    }

    func testLanguageRoundTripsAndToleratesMissingFields() throws {
        let language = MeetingLanguage(callLocale: "fr-FR", scriptLanguage: nil, recapLanguage: "en-GB")
        let record = MeetingRecord(name: "x", presetID: "p", presetName: "P", language: language, replyModel: "m")
        XCTAssertEqual(try JSONDecoder().decode(MeetingRecord.self, from: JSONEncoder().encode(record)).language, language)

        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(MeetingLanguage.self, from: Data(#"{"callLocale":"es-MX"}"#.utf8)), MeetingLanguage(callLocale: "es-MX"))
        XCTAssertEqual(try decoder.decode(MeetingLanguage.self, from: Data(#"{}"#.utf8)), .english)
        XCTAssertEqual(try decoder.decode(MeetingLanguage.self, from: Data(#"{"callLocale":"it-IT","detect":true}"#.utf8)).callLocale, "it-IT")
    }

    // MARK: - Prompts

    func testLanguageIsInTheCachedMeetingBlockNotTheRules() throws {
        let builder = ReplyPromptBuilder(model: .haiku55)
        let english = builder.request(meeting: meeting(.english), ask: ask())
        let german = builder.request(meeting: meeting(MeetingLanguage(callLocale: "de-DE")), ask: ask())
        // The rules and About me are one cached prefix for every language.
        XCTAssertEqual(german.system, english.system)
        XCTAssertEqual(german.cacheBreakpointCount, english.cacheBreakpointCount)

        let content = german.messages[0].content
        let style = try XCTUnwrap(content.first { $0.text?.contains("<reply_style ") == true })
        XCTAssertNotNil(style.cacheControl)
        XCTAssertTrue(style.text?.contains("<language>\nThe call is in German (Germany), de-DE.\nWrite the script and any questions in German (Germany), de-DE.\n</language>") == true, style.text ?? "")
        XCTAssertFalse(content.last?.text?.contains("<language>") == true, "not in the uncached tail")

        // Ask questions shares the same block.
        let questions = builder.questionsRequest(meeting: meeting(MeetingLanguage(callLocale: "de-DE")), ask: QuestionsAsk(recentTurns: ask().recentTurns))
        XCTAssertEqual(Array(questions.messages[0].content.dropLast()), Array(content.dropLast()))

        let override = ReplyPromptBuilder.languageText(MeetingLanguage(callLocale: "en-US", scriptLanguage: "es-MX"))
        XCTAssertTrue(override.contains("The call is in English (United States), en-US."))
        XCTAssertTrue(override.contains("Write the script and any questions in Spanish (Mexico), es-MX."))
    }

    func testNothingForcesEnglish() {
        let texts = [Prompts.replyRules, Prompts.questionsTask, Prompts.recapRules, Prompts.recapChunkInstruction]
        for text in texts {
            XCTAssertTrue(text.contains("in the language given in <language>"), String(text.prefix(60)))
            for phrase in ["always in English", "script in English", "spoken English", "plain English", "simple English", "polite English", "English sentences", "English speakers"] {
                XCTAssertFalse(text.contains(phrase), "\"\(phrase)\" in: \(text.prefix(60))")
            }
        }
    }

    func testFillersAreEnglishExamplesOfAFunction() {
        let rules = Prompts.replyRules
        XCTAssertTrue(rules.contains("a filled pause, a hesitation, a quick reaction, a connector"))
        XCTAssertTrue(rules.contains("In English, for example: \"um\", \"uh\""))
        XCTAssertTrue(rules.contains("In another language, use what its speakers naturally say for each of these."))
        XCTAssertTrue(rules.contains("The quoted examples in these rules and in <reply_style> are English."))
        XCTAssertTrue(Prompts.questionsTask.contains("in English, for example \"So,\""))
        XCTAssertTrue(rules.contains("(in English, for example: \"Uh, I'd rather not guess"))
    }

    func testRegisterFollowsTheMeetingAndTheLanguage() {
        let rules = Prompts.replyRules
        XCTAssertTrue(rules.contains("Formal or informal address"))
        XCTAssertTrue(rules.contains("what is usual for this kind of meeting in that language"))
        XCTAssertTrue(rules.contains("When unsure, start polite and follow their lead."))
    }

    func testNumberMarkerIsTheSameInEveryLanguage() {
        XCTAssertTrue(Prompts.replyRules.contains("put [confirm number] right after that sentence. Write that marker exactly as shown, in English and in square brackets, whatever language the script is in"))
    }

    func testRecapIsWrittenInTheRecapLanguage() throws {
        let start = Date(timeIntervalSince1970: 0)
        let record = MeetingRecord(
            name: "Kickoff", startedAt: start, presetID: "p", presetName: "P",
            language: MeetingLanguage(callLocale: "de-DE", recapLanguage: "en-GB"),
            turns: [TranscriptTurn(speaker: .them, finalText: "Hallo", startedAt: start)],
            replyModel: "m"
        )
        let builder = RecapPromptBuilder(model: .opus55)
        let text = try XCTUnwrap(builder.recapRequest(record: record, aboutMe: "").messages[0].content.last?.text)
        XCTAssertTrue(text.hasPrefix("<language>\nThe meeting was in German (Germany), de-DE.\nWrite the recap in English (United Kingdom), en-GB.\n</language>"), text)

        let part = try XCTUnwrap(builder.partRequest(record: record, aboutMe: "", part: "x", index: 0, total: 2).messages[0].content.first?.text)
        XCTAssertTrue(part.hasPrefix("<language>\n"))
        XCTAssertTrue(part.hasSuffix(Prompts.recapChunkInstruction))

        // Old meetings recap in English, as before.
        let old = MeetingRecord(name: "", presetID: "p", presetName: "P", replyModel: "m")
        XCTAssertTrue(builder.recapRequest(record: old, aboutMe: "").messages[0].content.last?.text?.contains("Write the recap in English (United States), en-US.") == true)
    }

    // MARK: - Number marker and questions

    func testMarkerVariantsAreNormalized() {
        let variants = ["[Confirm Number]", "[CONFIRM NUMBER]", "[confirm-number]", "[ confirm_number ]", "［confirm number］", "【confirm number】"]
        for variant in variants {
            let script = "Lass mich die genaue Zahl prüfen und mich melden. \(variant) Können wir zuerst über den Zeitplan sprechen?"
            let clean = ScriptText.sanitize(script)
            XCTAssertTrue(clean.contains(ScriptText.confirmNumberMarker), variant)
            XCTAssertEqual(ScriptText.splitFirstSentence(clean).first, "Lass mich die genaue Zahl prüfen und mich melden. [confirm number]", variant)
            XCTAssertTrue(ScriptText.containsMarker(script), variant)
        }
        XCTAssertFalse(ScriptText.containsMarker("Please confirm the number by Friday."))
        XCTAssertEqual(ScriptText.normalizingMarkers("No marker here."), "No marker here.")

        var reply = ReplyScript(targetTurnIDs: [], targetText: "", intent: .auto, steer: "", variant: .fresh, presetName: "", model: "")
        reply.text = "Je vérifie le chiffre exact. [Confirm number]"
        XCTAssertTrue(reply.needsNumberConfirmation)
    }

    func testQuestionsInOtherScriptsAreRecognized() {
        XCTAssertEqual(ScriptText.questions(from: "¿Quién más decide?\n予算はどのくらいですか？\nما هو الموعد النهائي؟\nGracias.", final: true),
                       ["¿Quién más decide?", "予算はどのくらいですか？", "ما هو الموعد النهائي؟"])
    }

    // MARK: - Echo filter

    func testGarbledEchoRulesRunOnlyForEnglish() {
        XCTAssertEqual(TranscriptStore.Configuration().language, "en-US")
        XCTAssertTrue(TranscriptStore.Configuration().removesGarbledEcho)
        XCTAssertTrue(TranscriptStore.Configuration(language: "en-GB").removesGarbledEcho)
        XCTAssertFalse(TranscriptStore.Configuration(language: "de-DE").removesGarbledEcho)

        var english = TranscriptStore()
        english.apply(.init(speaker: .them, kind: .final, text: Bleed.them), at: at(0))
        english.apply(.init(speaker: .you, kind: .final, text: Bleed.echo), at: at(2.5))
        XCTAssertEqual(english.turns.map(\.speaker), [.them])

        // The same garbled copy in a German call stays: the rule's stems, sound
        // keys and function words are English, so it would misjudge German words.
        var german = TranscriptStore(configuration: .init(language: "de-DE"))
        german.apply(.init(speaker: .them, kind: .final, text: Bleed.them), at: at(0))
        german.apply(.init(speaker: .you, kind: .volatile, text: "The recent Saudi effects involve women's healthies, the plane, strikes"), at: at(1))
        german.apply(.init(speaker: .you, kind: .final, text: Bleed.echo), at: at(2.5))
        XCTAssertEqual(german.turns.map(\.speaker), [.them, .you])
        XCTAssertEqual(german.droppedEchoSegments, 0)

        // Also when it arrives before their text.
        for (language, expected) in [("en-US", [Speaker.them]), ("de-DE", [.them, .you])] {
            var late = TranscriptStore(configuration: .init(language: language))
            late.apply(.init(speaker: .them, kind: .volatile, text: "The recent Saudi attacks"), at: at(0))
            late.apply(.init(speaker: .you, kind: .final, text: Bleed.echo), at: at(1))
            late.apply(.init(speaker: .them, kind: .final, text: Bleed.them), at: at(4))
            XCTAssertEqual(late.turns.map(\.speaker), expected, language)
        }
    }

    func testNearVerbatimEchoIsRemovedInAnyLanguage() {
        var store = TranscriptStore(configuration: .init(language: "de-DE"))
        store.apply(.init(speaker: .them, kind: .final, text: "Wir können die neue Seite in zwei Wochen starten."), at: at(0))
        store.apply(.init(speaker: .you, kind: .volatile, text: "können die neue Seite in zwei"), at: at(0.4))
        XCTAssertEqual(store.turns.map(\.speaker), [.them], "live echo never shows")
        store.apply(.init(speaker: .you, kind: .final, text: "wir können die neue Seite in zwei Wochen starten"), at: at(0.8))
        XCTAssertEqual(store.turns.map(\.speaker), [.them])
        XCTAssertEqual(store.droppedEchoSegments, 1)

        // The user's own answer still comes through.
        store.apply(.init(speaker: .you, kind: .final, text: "Ja, das passt gut, dann planen wir den Start für Mitte Mai."), at: at(3))
        XCTAssertEqual(store.turns.map(\.speaker), [.them, .you])
    }
}
