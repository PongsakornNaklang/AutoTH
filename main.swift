// AutoTH — auto-switch EN/TH keyboard layout from what you're typing.
// Listens to keystrokes (CGEventTap), keeps the current word's key codes, reads them
// through BOTH layouts, and if the other layout makes more sense: erase, switch, retype.
import AppKit
import Carbon
import ServiceManagement

enum Lang { case en, th }
struct Key { let code: UInt16; let shift: Bool }

// MARK: - Layouts (read from the user's own enabled layouts via UCKeyTranslate, no hardcoded table)

struct Layout {
    let id: String, src: TISInputSource, data: Data
    func text(_ keys: [Key]) -> String {
        data.withUnsafeBytes { p -> String in
            let kl = p.baseAddress!.assumingMemoryBound(to: UCKeyboardLayout.self)
            var out = ""
            for k in keys {
                var dead: UInt32 = 0, len = 0, buf = [UniChar](repeating: 0, count: 4)
                UCKeyTranslate(kl, k.code, UInt16(kUCKeyActionDown), k.shift ? 2 : 0, UInt32(LMGetKbdType()),
                               OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &buf)
                out += String(utf16CodeUnits: buf, count: len)
            }
            return out
        }
    }
}

func prop<T>(_ s: TISInputSource, _ k: CFString) -> T? {
    TISGetInputSourceProperty(s, k).map { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() as! T }
}

func findLayout(_ lang: String) -> Layout? {
    let filter = [kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource!,
                  kTISPropertyInputSourceIsSelectCapable: true] as CFDictionary
    let list = TISCreateInputSourceList(filter, false).takeRetainedValue() as! [TISInputSource]
    for s in list {
        guard let langs: [String] = prop(s, kTISPropertyInputSourceLanguages), langs.first?.hasPrefix(lang) == true,
              let data: Data = prop(s, kTISPropertyUnicodeKeyLayoutData), let id: String = prop(s, kTISPropertyInputSourceID)
        else { continue }
        return Layout(id: id, src: s, data: data)
    }
    return nil
}

// MARK: - Detector

let spell = NSSpellChecker.shared
let lettersOnly = { (s: String) in !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0 == "'") } }

func enValid(_ raw: String) -> Bool {
    let s = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?\""))
    if s.count == 1 { return "aAI".contains(s) }
    return lettersOnly(s) && spell.checkSpelling(of: s, startingAt: 0, language: "en", wrap: false,
                                                  inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
}

/// "wrok", "teh": an English word with two adjacent letters swapped, not Thai typed on the wrong layout.
func enTypo(_ s: String) -> Bool {
    guard lettersOnly(s), s.count >= 3 else { return false }
    let guesses = spell.guesses(forWordRange: NSRange(location: 0, length: s.utf16.count), in: s, language: "en", inSpellDocumentWithTag: 0) ?? []
    let a = Array(s.lowercased())
    return guesses.contains { g in
        let b = Array(g.lowercased()), d = a.indices.filter { b.count == a.count && a[$0] != b[$0] }
        return d.count == 2 && d[1] == d[0] + 1 && a[d[0]] == b[d[1]] && a[d[1]] == b[d[0]]
    }
}

func enHasCompletions(_ s: String) -> Bool {
    lettersOnly(s) && !(spell.completions(forPartialWordRange: NSRange(location: 0, length: s.utf16.count), in: s,
                                          language: "en", inSpellDocumentWithTag: 0) ?? []).isEmpty
}

// ponytail: Thai has no spell-checker on macOS, so "plausible" = obeys Thai spelling rules (syllable shape).
// Ceiling: rule-legal nonsense passes. Upgrade path: bundle a Thai word list / n-gram model.
let C = "\\u0E01-\\u0E2E", LV = "\\u0E40-\\u0E44", AV = "\\u0E31\\u0E34-\\u0E39\\u0E47", TN = "\\u0E48-\\u0E4B"
let thaiShape = try! NSRegularExpression(pattern:
    "^(?:[\(LV)]?[\(C)](?:[\(AV)][\(TN)]?|[\(TN)][\(AV)]?)?\\u0E4C?(?:\\u0E32?\\u0E30|[\\u0E32\\u0E33\\u0E45])?[\\u0E46]?)+$")
let thaiBad = try! NSRegularExpression(pattern:
    "[\\u0E43\\u0E44][\(C)][\(TN)]?[\(AV)\\u0E30\\u0E32\\u0E33]|[\\u0E40\\u0E41\\u0E42][\(C)][\(TN)]?\\u0E33|\\u0E31[\(TN)]?[\\u0E30\\u0E32\\u0E33]")
let thaiBadEnd = try! NSRegularExpression(pattern: "\\u0E31[\(TN)]?$")

func thPlausible(_ raw: String, prefix: Bool) -> Bool {
    var s = raw
    if prefix { while let l = s.unicodeScalars.last, (0x0E40...0x0E44).contains(l.value) { s.unicodeScalars.removeLast() } }
    if s.isEmpty { return prefix }
    let r = NSRange(location: 0, length: s.utf16.count)
    return thaiShape.firstMatch(in: s, range: r) != nil && thaiBad.firstMatch(in: s, range: r) == nil
        && (prefix || thaiBadEnd.firstMatch(in: s, range: r) == nil)
}

// Thai word list (ICU's thaidict.txt, Unicode license), bundled in the app's Resources.
let thaiWords: Set<[Unicode.Scalar]> = {
    guard let url = Bundle.main.url(forResource: "thaidict", withExtension: "txt"),
          let txt = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return Set(txt.split(whereSeparator: \.isNewline).map { Array($0.trimmingCharacters(in: .whitespaces).unicodeScalars) }
        .filter { $0.first.map { (0x0E01...0x0E2E).contains($0.value) || (0x0E40...0x0E44).contains($0.value) } ?? false })
}()
let maxWordLen = thaiWords.map(\.count).max() ?? 0
let minThaiCoverage = 0.9  // tuning knob: higher = fewer wrong switches to Thai, more missed Thai (loanwords)

/// Share of the text (0...1) made of dictionary words, best split via DP. "สวัสดีครับ" → 1.0, "ฟกีสะนรก" → low.
func thWords(_ s: String) -> Double {
    let a = Array(s.unicodeScalars)
    guard !a.isEmpty else { return 0 }
    var best = [Int](repeating: 0, count: a.count + 1)
    for i in 1...a.count {
        best[i] = best[i - 1] + (a[i - 1] == "\u{0E46}" ? 1 : 0)  // ๆ counts as fine
        for j in max(0, i - maxWordLen)..<i where best[j] + i - j > best[i] && thaiWords.contains(Array(a[j..<i])) { best[i] = best[j] + i - j }
    }
    return Double(best[a.count]) / Double(a.count)
}

/// Thai typo fix at word end: a key pressed twice (ทที่ไหน), else a vowel/tone mark typed in the wrong order
/// (ท่ี → ที่). Only when the result is all dictionary words and there's exactly one such fix.
// ponytail: no missing-key or wrong-key fixes yet (many more candidates = more wrong fixes); add if measured worth it.
let isMark = { (u: Unicode.Scalar) in u.value == 0x0E31 || (0x0E34...0x0E3A).contains(u.value) || (0x0E47...0x0E4E).contains(u.value) }
func thaiFix(_ s: String) -> String? {
    let a = Array(s.unicodeScalars)
    guard a.count >= 3, thWords(s) < 1 else { return nil }
    func pick(_ cands: [[Unicode.Scalar]]) -> String? {
        let ok = Set(cands.map { String(String.UnicodeScalarView($0)) }.filter { thPlausible($0, prefix: false) && thWords($0) == 1 })
        return ok.count == 1 ? ok.first : nil
    }
    let pairs = a.indices.dropLast()
    return pick(pairs.filter { a[$0] == a[$0 + 1] }.map { i in var b = a; b.remove(at: i); return b })
        ?? pick(pairs.filter { isMark(a[$0]) && isMark(a[$0 + 1]) }.map { i in var b = a; b.swapAt(i, i + 1); return b })
}

/// Which language the user meant, or nil = leave it. `final` = word just ended (space/enter/tab).
func decide(en: String, th: String, current: Lang, final: Bool) -> Lang? {
    if en.allSatisfy({ $0.isASCII && $0.isNumber }) { return nil }  // 555, 2024, phone numbers: leave alone
    switch (current, final) {
    case (.en, true):  // e.g. "l;ylfu" -> สวัสดี
        return !enValid(en) && !enTypo(en) && thPlausible(th, prefix: false) && thWords(th) >= minThaiCoverage ? .th : nil
    case (.en, false): // mid-word only on strong signal: Thai-only keys (; [ ] , . / digits) inside an English non-word
        return en.count >= 3 && en.contains(where: { ";,./[]\\-=0123456789".contains($0) })
            && !enValid(en) && !enHasCompletions(en) && thPlausible(th, prefix: true) ? .th : nil
    case (.th, true):  // e.g. "ะ้ำ" -> the
        return enValid(en) && (lettersOnly(en) && en.count >= 4 || !thPlausible(th, prefix: false) || thWords(th) < minThaiCoverage) ? .en : nil
    case (.th, false):
        return en.count >= 3 && !thPlausible(th, prefix: true) && (enValid(en) || enHasCompletions(en)) ? .en : nil
    }
}

// MARK: - Keyboard hook

var EN: Layout!, TH: Layout!
var keys: [Key] = [], convertedThisWord = false, laughing = false, enabled = true, tap: CFMachPort?
/// User-set undo shortcut (Settings window), saved in UserDefaults. Default ⌃Space.
struct Shortcut {
    static let modMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
    var code: UInt16, mods: CGEventFlags
    var label: String {
        let names: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Esc"]
        return (mods.contains(.maskControl) ? "⌃" : "") + (mods.contains(.maskAlternate) ? "⌥" : "")
            + (mods.contains(.maskShift) ? "⇧" : "") + (mods.contains(.maskCommand) ? "⌘" : "")
            + (names[code] ?? EN.text([Key(code: code, shift: false)]).uppercased())
    }
    func matches(_ e: CGEvent, code: UInt16) -> Bool { code == self.code && e.flags.intersection(Shortcut.modMask) == mods }
}
var undoShortcut: Shortcut = {
    let d = UserDefaults.standard
    guard d.object(forKey: "undoCode") != nil else { return Shortcut(code: 49, mods: .maskControl) }
    return Shortcut(code: UInt16(d.integer(forKey: "undoCode")), mods: CGEventFlags(rawValue: UInt64(d.integer(forKey: "undoMods"))))
}()
var recording: ((Shortcut?) -> Void)?  // set while the Settings window waits for a new shortcut

/// What the undo shortcut puts back after an auto change: erase `screen`, switch to `back` (if the layout changed), type `original`.
struct Undo { var screen: String, original: String; let back: Layout?, fwd: Layout }
var undo: Undo?, skipWord = false  // skipWord: user undid a mid-word switch, leave the rest of that word alone
let magic: Int64 = 0x4155_5448  // tags our own synthetic events so we ignore them
let src = CGEventSource(stateID: .privateState)

func post(_ e: CGEvent) { e.setIntegerValueField(.eventSourceUserData, value: magic); e.post(tap: .cghidEventTap) }
func backspace(_ n: Int) {
    for _ in 0..<n { for d in [true, false] { let e = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: d)!; e.flags = []; post(e) } }
}
func typeText(_ s: String) {
    for ch in s {
        let u = Array(String(ch).utf16)
        for d in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: d)!
            e.flags = []; e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u); post(e)
        }
    }
}
func whenModifiersReleased(_ f: @escaping () -> Void) {
    if CGEventSource.flagsState(.hidSystemState).intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty { return f() }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { whenModifiersReleased(f) }
}
func currentLang() -> Lang? {
    let id: String? = prop(TISCopyCurrentKeyboardInputSource().takeRetainedValue(), kTISPropertyInputSourceID)
    return id == EN.id ? .en : id == TH.id ? .th : nil
}
func reset() { keys = []; convertedThisWord = false; laughing = false; skipWord = false }

/// Returns true if it erased + retyped the word (in the other language and/or with a Thai typo fixed).
func tryConvert(final: Bool, typedSoFar: Int) -> Bool {
    guard keys.count >= 2, let cur = currentLang() else { return false }
    let target = decide(en: EN.text(keys), th: TH.text(keys), current: cur, final: final)
    let lang = target ?? cur
    var text = (lang == .th ? TH : EN).text(keys)
    if final && lang == .th, let fixed = thaiFix(text) { text = fixed } else if target == nil { return false }
    backspace(typedSoFar)
    if let target { TISSelectInputSource((target == .th ? TH : EN).src) }
    typeText(text)
    let curLayout: Layout = cur == .th ? TH : EN
    undo = Undo(screen: text, original: curLayout.text(keys), back: target == nil ? nil : curLayout, fwd: lang == .th ? TH : EN)
    return true
}

let resetKeys: Set<UInt16> = [53, 117, 115, 119, 116, 121, 123, 124, 125, 126]  // esc, fwd-del, home/end/pg, arrows
let boundaryKeys: Set<UInt16> = [49, 36, 76, 48]  // space, return, enter, tab

let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { CGEvent.tapEnable(tap: tap!, enable: true); return .passUnretained(event) }
    guard event.getIntegerValueField(.eventSourceUserData) != magic else { return .passUnretained(event) }
    guard type == .keyDown else { reset(); undo = nil; return .passUnretained(event) }  // mouse click = caret moved

    let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    if let done = recording {  // Settings is waiting for a new undo shortcut; caught here so system shortcuts work too
        if code == 53 { done(nil); return nil }  // Esc cancels
        let mods = event.flags.intersection(Shortcut.modMask)
        if mods.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty { return .passUnretained(event) }
        done(Shortcut(code: code, mods: mods)); return nil
    }
    guard enabled else { return .passUnretained(event) }
    // Undo shortcut right after an auto change: put back what the user typed (and its layout).
    // Otherwise the shortcut passes through (⌃Space stays macOS's own "switch input source").
    if undoShortcut.matches(event, code: code), let u = undo {
        whenModifiersReleased {  // typed while ⌃/⌘/⌥ is down, our text would arrive as shortcuts (⌃H = delete…)
            backspace(u.screen.unicodeScalars.count)
            if let back = u.back { TISSelectInputSource(back.src) }
            typeText(u.original)
        }
        let midWord = convertedThisWord && !keys.isEmpty
        reset(); undo = nil; skipWord = midWord
        return nil
    }
    if !event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty || resetKeys.contains(code) {
        reset(); undo = nil; return .passUnretained(event)
    }
    if code == 51 { if !keys.isEmpty { keys.removeLast() }; undo = nil; return .passUnretained(event) }
    if boundaryKeys.contains(code) {
        let did = tryConvert(final: true, typedSoFar: keys.count)
        if code == 49, var u = undo { u.screen += " "; u.original += " "; undo = u } else { undo = nil }  // no undo past Enter/Tab
        reset()
        if did { post(event.copy()!); return nil }  // re-send the space/enter after the retyped word
        return .passUnretained(event)
    }
    let key = Key(code: code, shift: event.flags.contains(.maskShift))
    guard let ch = EN.text([key]).unicodeScalars.first, ch.value >= 0x20, ch.value != 0x7F, ch.value < 0xF700 else {
        reset(); undo = nil; return .passUnretained(event)  // function keys etc.
    }
    if skipWord { return .passUnretained(event) }
    // Thai laughter: on the Thai layout the 5 key is ถ. Third 5 in a row → "555", and further 5s stay digits.
    if ch == "5" && currentLang() == .th {
        if laughing { typeText("5"); return nil }
        if EN.text(Array(keys.suffix(2))) == "55" { backspace(2); typeText("555"); reset(); undo = nil; laughing = true; return nil }
    }
    laughing = false
    // After a mid-word switch, keep the undo in step with what's typed until the word ends.
    if var u = undo, convertedThisWord, let back = u.back { u.screen += u.fwd.text([key]); u.original += back.text([key]); undo = u } else { undo = nil }
    keys.append(key)
    if !convertedThisWord && tryConvert(final: false, typedSoFar: keys.count - 1) {
        convertedThisWord = true
        return nil  // swallowed: already retyped including this key
    }
    return .passUnretained(event)
}

// MARK: - Self-check: `AutoTH --selftest`

func selfTest() -> Int32 {
    var rev: [Unicode.Scalar: Key] = [:]
    func index(_ l: Layout) { rev = [:]; for c in 0..<128 { for s in [false, true] { let k = Key(code: UInt16(c), shift: s); if let ch = l.text([k]).unicodeScalars.first, rev[ch] == nil { rev[ch] = k } } } }
    // Type `word` on `layout` key by key, starting in `start` mode; return which language it ends up in.
    func simulate(_ word: String, on layout: Layout, start: Lang) -> Lang {
        index(layout)
        let ks = word.unicodeScalars.map { rev[$0]! }
        var cur = start, done = false
        for i in 2...ks.count where !done && i < ks.count {
            let p = Array(ks[..<i])
            if let t = decide(en: EN.text(p), th: TH.text(p), current: cur, final: false) { cur = t; done = true }
        }
        return decide(en: EN.text(ks), th: TH.text(ks), current: cur, final: true) ?? cur
    }
    let thai = "สวัสดี ครับ ค่ะ ขอบคุณ วันนี้ กินข้าว ไปไหน ทำงาน ไม่ได้ อะไร เท่าไหร่ ภาษาไทย แล้ว เพราะ เป็น อยู่ ที่ไหน พรุ่งนี้ เมื่อวาน กรุงเทพ โทรศัพท์ ประชุม น้ำ ข้าว รัก มาก เลย เรื่อง เขา ใจดี ไม่ใช่ หิว นอน ผม ไหม ความรัก ขอโทษ เดี๋ยว ตอนนี้"
    let english = "hello the work world thanks meeting please today computer keyboard language because should would people time good make with have this that from about where there yes okay"
    let stayEnglish = "recieve teh wrok thier langauge keybaord becuase adn form hte waht jsut btn cfg npm git ssh http json figma redis xcode mongodb supabase prisma claude lazada canva"
    var fails: [String] = []
    for w in thai.split(separator: " ").map(String.init) {
        if simulate(w, on: TH, start: .en) != .th { fails.append("TH word typed in EN mode not fixed: \(w) (\(EN.text(w.unicodeScalars.map { rev[$0]! })))") }
        if simulate(w, on: TH, start: .th) != .th { fails.append("TH word wrongly switched to EN: \(w)") }
    }
    for w in english.split(separator: " ").map(String.init) {
        if simulate(w, on: EN, start: .th) != .en { fails.append("EN word typed in TH mode not fixed: \(w) (\(TH.text(w.unicodeScalars.map { rev[$0]! })))") }
        if simulate(w, on: EN, start: .en) != .en { fails.append("EN word wrongly switched to TH: \(w)") }
    }
    for w in stayEnglish.split(separator: " ").map(String.init) where simulate(w, on: EN, start: .en) != .en {
        fails.append("EN typo/code wrongly switched to TH: \(w)")
    }
    for w in ["555", "55555", "2024"] where simulate(w, on: EN, start: .en) != .en { fails.append("number switched to Thai: \(w)") }
    for (typo, want) in [("ทที่ไหน", "ที่ไหน"), ("ไปปไหน", "ไปไหน"), ("สวัสดีีครับ", "สวัสดีครับ"), ("ท่ีไหน", "ที่ไหน"),
                         ("ที่ไหน", nil), ("อื่นๆ", nil), ("วีลแชร์", nil), ("คลาสสิก", nil)] as [(String, String?)]
    where thaiFix(typo) != want { fails.append("Thai typo fix: \(typo) → \(thaiFix(typo) ?? "nil"), want \(want ?? "nil")") }
    // Known collisions, left alone on purpose: ทำไม = "mew,", ทำ = "me" (real English on the EN layout).
    fails.forEach { print("FAIL", $0) }
    print(fails.isEmpty ? "selftest OK" : "\(fails.count) failures")
    return fails.isEmpty ? 0 : 1
}

// MARK: - App

guard let en = findLayout("en"), let th = findLayout("th") else {
    print("Need both an English and a Thai keyboard enabled in System Settings › Keyboard › Input Sources"); exit(1)
}
EN = en; TH = th
guard !thaiWords.isEmpty else { print("thaidict.txt missing from app Resources — build with ./build.sh"); exit(1) }
if CommandLine.arguments.contains("--selftest") { exit(selfTest()) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
item.button?.title = "ก⇄A"

func openAccessibilitySettings() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
}

final class Settings: NSObject, NSWindowDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 100), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
    let button = NSButton(title: undoShortcut.label, target: nil, action: nil)
    override init() {
        super.init()
        window.title = "AutoTH Settings"; window.isReleasedWhenClosed = false; window.delegate = self
        button.target = self; button.action = #selector(record)
        let hint = NSTextField(labelWithString: "Click the button, then press the new shortcut. Esc cancels.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [NSStackView(views: [NSTextField(labelWithString: "Undo last auto change:"), button]), hint])
        stack.orientation = .vertical; stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        window.contentView = stack; window.center()
    }
    func show() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc func record() {
        button.title = "Press shortcut…"
        recording = { [weak self] new in
            recording = nil
            if let new {
                undoShortcut = new
                UserDefaults.standard.set(Int(new.code), forKey: "undoCode")
                UserDefaults.standard.set(Int(new.mods.rawValue), forKey: "undoMods")
            }
            self?.button.title = undoShortcut.label
        }
    }
    func windowWillClose(_ n: Notification) { recording = nil; button.title = undoShortcut.label }
}
var settings: Settings?

final class Menu: NSObject {
    @objc func openSettings() { if settings == nil { settings = Settings() }; settings!.show() }
    @objc func toggle(_ s: NSMenuItem) { enabled.toggle(); reset(); s.state = enabled ? .on : .off; item.button?.title = enabled ? "ก⇄A" : "ก·A" }
    @objc func openAX() { openAccessibilitySettings() }
    @objc func toggleLogin(_ s: NSMenuItem) {
        let login = SMAppService.mainApp
        do { if login.status == .enabled { try login.unregister() } else { try login.register() } }
        catch { NSLog("AutoTH: login item: \(error)") }
        if login.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }  // macOS wants the user to OK it
        s.state = login.status == .enabled ? .on : .off
    }
}
let target = Menu()
let menu = NSMenu()
let toggleItem = menu.addItem(withTitle: "Auto-switch EN/TH", action: #selector(Menu.toggle(_:)), keyEquivalent: "")
toggleItem.target = target; toggleItem.state = .on
let loginItem = menu.addItem(withTitle: "Open at Login", action: #selector(Menu.toggleLogin(_:)), keyEquivalent: "")
loginItem.target = target; loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
menu.addItem(withTitle: "Settings…", action: #selector(Menu.openSettings), keyEquivalent: ",").target = target
menu.addItem(withTitle: "Open Accessibility Settings…", action: #selector(Menu.openAX), keyEquivalent: "").target = target
menu.addItem(.separator())
menu.addItem(withTitle: "Quit AutoTH", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
item.menu = menu

// Needs Accessibility permission; keep retrying until the user grants it.
_ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
func installTap() -> Bool {
    let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
    guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: CGEventMask(mask), callback: callback, userInfo: nil) else { return false }
    tap = t
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
    return true
}
if installTap() {
    NSLog("AutoTH: key tap running")
} else {  // no permission yet: show ⚠ until the user grants Accessibility
    NSLog("AutoTH: waiting for Accessibility permission")
    item.button?.title = "ก⚠A"
    openAccessibilitySettings()
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
        if installTap() { t.invalidate(); item.button?.title = "ก⇄A"; NSLog("AutoTH: key tap running") }
    }
}
app.run()
