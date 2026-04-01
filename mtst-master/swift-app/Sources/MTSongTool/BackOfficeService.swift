import Foundation

// MARK: - Errors

enum BOError: LocalizedError {
    case notLoggedIn
    case loginFailed(String)
    case networkError(String)
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:           return "Not logged in to BackOffice. Add credentials in ⚙ Settings."
        case .loginFailed(let msg):  return "BackOffice login failed: \(msg)"
        case .networkError(let msg): return "Network error: \(msg)"
        case .uploadFailed(let msg): return "Upload failed: \(msg)"
        }
    }
}

// MARK: - BackOfficeService

@MainActor
final class BackOfficeService: ObservableObject {

    // MARK: Published state
    @Published var isLoggingIn  = false
    @Published var isLoggedIn   = false
    @Published var isLoading    = false
    @Published var isUploading  = false
    @Published var uploadComplete = false
    @Published var isTriggeringUploadStems = false
    @Published var uploadStemsComplete = false
    @Published var uploadStemsBlockedShellURL: URL? = nil
    @Published var lastError: String? = nil
    @Published var fetchedTitle  = ""
    @Published var fetchedStatus = ""
    @Published var hasStemSet    = false

    // MARK: Private
    private let baseURL = "https://backoffice.multitracks.com"
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage   = HTTPCookieStorage.shared
        config.httpCookieAcceptPolicy = .always
        config.httpShouldSetCookies = true
        session = URLSession(configuration: config)
    }

    func reset() {
        fetchedTitle  = ""
        fetchedStatus = ""
        hasStemSet    = false
        lastError     = nil
        uploadComplete = false
        uploadStemsComplete = false
        uploadStemsBlockedShellURL = nil
        // isLoggedIn intentionally preserved — session cookie survives MTID changes
    }

    // MARK: - Public API

    /// Proactively establish a BackOffice session using stored credentials.
    /// Call this when the Upload tab opens so the session is ready before the user acts.
    /// Uses loadPage() as a probe rather than calling login() unconditionally — if the
    /// session cookie is still valid the probe returns immediately without a login POST.
    func ensureLoggedIn() async {
        guard !isLoggedIn, !isLoggingIn else { return }
        let creds = storedCredentials()
        guard !creds.username.isEmpty, !creds.password.isEmpty else { return }
        isLoggingIn = true
        lastError   = nil
        defer { isLoggingIn = false }
        do {
            // Any auth-required page works as a probe. If the cookie is valid,
            // loadPage returns immediately. If expired, it auto-logins via login()
            // (which sets isLoggedIn = true) then retries.
            _ = try await loadPage(path: "/songs/")
            isLoggedIn = true
        } catch is CancellationError {
            // Task cancelled — not an error worth showing
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            // URLSession cancellation — same as CancellationError, not user-facing
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Fetch song title + status from the BackOffice edit page.
    /// Auto-logins with stored credentials if the session has expired.
    func fetchSongData(mtid: String) async {
        guard !mtid.isEmpty else { reset(); return }
        // Don't attempt auto-login here — ensureLoggedIn() owns that.
        // UploadView re-triggers fetchSongData via .onChange(of: isLoggedIn) once login completes.
        guard isLoggedIn else { lastError = nil; return }
        isLoading = true
        lastError = nil
        defer { isLoading = false }
        do {
            let html   = try await loadPage(path: "/songs/edit.aspx?id=\(mtid)")
            let fields = formFields(from: html)
            fetchedTitle  = extractTitle(from: html, fields: fields)
            fetchedStatus = statusLabel(for: fields["status"] ?? "")
            let shellHTML = try await loadPage(path: "/songs/details.aspx?id=\(mtid)")
            hasStemSet = hasStemSets(in: shellHTML)
        } catch is CancellationError {
            // Task cancelled (MTID changed mid-fetch) — not an error worth showing
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            // URLSession cancellation — same as CancellationError, not user-facing
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Upload the .als file + song metadata to the BackOffice edit page.
    ///
    /// Only sends the five data fields we own (bpm, key, timeSig, previewBegin/End)
    /// plus the .als file. ASP.NET ViewState preserves all other song metadata server-side,
    /// so nothing else on the song record is touched.
    func uploadSession(
        mtid: String,
        alsURL: URL,
        bpm: String,
        key: String,
        timeSig: String,
        previewStart: String,
        previewEnd: String,
        rehearsalMixOnly: Bool = false
    ) async {
        isUploading   = true
        uploadComplete = false
        uploadStemsComplete = false
        uploadStemsBlockedShellURL = nil
        lastError     = nil

        do {
            let editPath = "/songs/edit.aspx?id=\(mtid)"
            let editURL  = URL(string: baseURL + editPath)!

            // GET the edit page to discover ASP.NET field names and ViewState tokens.
            let html = try await loadPage(path: editPath)

            // Start with all existing form fields so ASP.NET-namespaced names are captured correctly.
            // Override only the 5 fields we own; ViewState preserves everything else server-side.
            // Use setField(endingWith:) to handle namespace mangling: "ctl00$cph$bpm" matched by "bpm".
            var fields = formFields(from: html)
            fields["bpm"]           = formatBPM(bpm)
            fields["originalKey"]   = keyID(for: key)
            fields["timesignature"] = timeSigID(for: timeSig)
            fields["previewBegin"]  = previewStart
            fields["previewEnd"]    = previewEnd
            fields["__EVENTTARGET"]   = ""
            fields["__EVENTARGUMENT"] = ""
            // Checkbox: include key when checked, remove when unchecked
            // (unchecked checkboxes are not sent in HTML form submissions)
            if rehearsalMixOnly {
                fields["rehearsalMixOnly"] = "on"
            } else {
                fields.removeValue(forKey: "rehearsalMixOnly")
            }

            // Discover the actual submit button name rather than hardcoding it —
            // ASP.NET WebForms mangles control IDs so "btnSave" is rarely the real name.
            if let (btnName, btnValue) = findSubmitButton(in: html) {
                fields[btnName] = btnValue
            }

            let alsData = try Data(contentsOf: alsURL)
            let (_, response) = try await postMultipart(
                to:          editURL,
                textFields:  fields,
                fileField:   "uploadAbleton",
                fileData:    alsData,
                fileName:    alsURL.lastPathComponent,
                mimeType:    "application/octet-stream"
            )
            guard let http = response as? HTTPURLResponse,
                  (200...399).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw BOError.uploadFailed("HTTP \(code)")
            }
            uploadComplete = true
        } catch is CancellationError {
            isUploading = false
            return
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            isUploading = false
            return
        } catch {
            lastError = error.localizedDescription
            isUploading = false
            return
        }

        isUploading = false
    }

    /// Trigger the "Upload Stems" action on the BackOffice song shell page.
    /// This fires __doPostBack('btnEngineering','') which creates the song folder on Nolan Ryan.
    /// If the Upload Stems button is absent (wrong status), sets lastError with the shell URL.
    func triggerUploadStems(mtid: String) async {
        isTriggeringUploadStems = true
        uploadStemsBlockedShellURL = nil
        defer { isTriggeringUploadStems = false }

        do {
            try await _triggerUploadStems(mtid: mtid)
            uploadStemsComplete = true
        } catch is CancellationError {
            // Task cancelled — not an error worth showing
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            // URLSession cancellation — same as CancellationError, not user-facing
        } catch TriggerStemsError.buttonNotAvailable(let shellURL) {
            uploadStemsBlockedShellURL = shellURL
            lastError = "Can't Create Folder — see Song Shell"
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Result-returning variant used by QueueService.processAll.
    /// Does NOT update published state — caller tracks per-item status.
    func triggerUploadStemsResult(mtid: String) async -> Result<Void, Error> {
        do {
            try await _triggerUploadStems(mtid: mtid)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Core Upload Stems POST logic — throws on failure.
    private func _triggerUploadStems(mtid: String) async throws {
        let shellPath = "/songs/details.aspx?id=\(mtid)"
        let shellURL  = URL(string: baseURL + shellPath)!
        let html      = try await loadPage(path: shellPath)

        // Upload Stems link is only present when engineering status allows it:
        // <a id="btnEngineering" ...href="javascript:__doPostBack('btnEngineering','')">
        guard html.range(of: "id=\"btnEngineering\"", options: .caseInsensitive) != nil else {
            throw TriggerStemsError.buttonNotAvailable(shellURL)
        }

        // POST __doPostBack('btnEngineering', '') — same mechanism as clicking the link
        var fields = formFields(from: html)
        fields["__EVENTTARGET"]   = "btnEngineering"
        fields["__EVENTARGUMENT"] = ""

        var req = URLRequest(url: shellURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(shellURL.absoluteString, forHTTPHeaderField: "Referer")
        req.httpBody = urlEncode(fields)

        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200...399).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BOError.uploadFailed("Upload Stems POST failed (HTTP \(code))")
        }
    }

    private enum TriggerStemsError: LocalizedError {
        case buttonNotAvailable(URL)
        var errorDescription: String? {
            if case .buttonNotAvailable(let url) = self {
                return "Upload Stems button not available — check song status (\(url.absoluteString))"
            }
            return nil
        }
    }

    // MARK: - Session / Login

    /// Load the page at `path`, auto-logging in if redirected to the login page.
    private func loadPage(path: String) async throws -> String {
        let url = URL(string: baseURL + path)!
        let (data, response) = try await session.data(from: url)
        let html = decode(data)

        // Detect redirect to login (URLSession follows 302 automatically)
        let finalPath = (response as? HTTPURLResponse)?.url?.path.lowercased() ?? ""

        if finalPath.contains("login") || isLoginPage(html) {
            let creds = storedCredentials()
            guard !creds.username.isEmpty, !creds.password.isEmpty else {
                throw BOError.notLoggedIn
            }
            // Pass the actual login page URL so login() doesn't need a second redirect
            let loginPageURL = (response as? HTTPURLResponse)?.url
            try await login(startURL: loginPageURL, username: creds.username, password: creds.password)
            let (retryData, retryResponse) = try await session.data(from: url)
            let retryHTML = decode(retryData)
            let retryPath = (retryResponse as? HTTPURLResponse)?.url?.path.lowercased() ?? ""
            // If still on login page after login, credentials failed or session didn't stick
            if retryPath.contains("login") || isLoginPage(retryHTML) {
                throw BOError.loginFailed("Login succeeded but session did not stick — check credentials in ⚙ Settings.")
            }
            return retryHTML
        }
        return html
    }

    private func login(startURL: URL? = nil, username: String, password: String) async throws {
        let defaultLoginURL = URL(string: baseURL + "/login.aspx")!

        // GET login page to extract ViewState + discover field names.
        // Start from the URL we were redirected to (if known) to avoid an extra hop.
        let (pageData, pageResponse) = try await session.data(from: startURL ?? defaultLoginURL)
        let pageHTML = decode(pageData)
        // POST to the URL we actually landed on — handles /login.aspx → /default.aspx redirects.
        let postURL = (pageResponse as? HTTPURLResponse)?.url ?? startURL ?? defaultLoginURL
        var fields  = formFields(from: pageHTML)

        guard let userField = findField(type: "email", in: pageHTML)
                           ?? findField(type: "text",  in: pageHTML),
              let passField = findField(type: "password", in: pageHTML) else {
            throw BOError.loginFailed("Login form not found — BackOffice layout may have changed.")
        }

        fields[userField]         = username
        fields[passField]         = password
        fields["__EVENTTARGET"]   = ""
        fields["__EVENTARGUMENT"] = ""
        if let (btnName, btnValue) = findSubmitButton(in: pageHTML) {
            fields[btnName] = btnValue
        }

        var req = URLRequest(url: postURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue(postURL.absoluteString, forHTTPHeaderField: "Referer")
        req.httpBody = urlEncode(fields)

        let (responseData, response) = try await session.data(for: req)
        let responseHTML = decode(responseData)
        let finalPath = (response as? HTTPURLResponse)?.url?.path.lowercased() ?? ""
        // Detect failure: still on a login page (path-based or content-based)
        if finalPath.contains("login") || isLoginPage(responseHTML) {
            let body = responseHTML.lowercased()
            let hint = body.contains("invalid") || body.contains("incorrect") || body.contains("failed")
                       ? "Invalid username or password." : "Login POST failed — check credentials in ⚙ Settings."
            throw BOError.loginFailed(hint)
        }
        isLoggedIn = true
    }

    private func isLoginPage(_ html: String) -> Bool {
        html.contains("type=\"password\"") &&
        (html.lowercased().contains("sign in") || html.lowercased().contains("login"))
    }

    private func storedCredentials() -> (username: String, password: String) {
        let username = UserSettings.shared.backOfficeUsername
        let password = CredentialStore.load(key: CredentialStore.backOfficePasswordKey) ?? ""
        return (username, password)
    }

    // MARK: - HTML Form Parsing

    /// Extract all form field name→value pairs.
    /// Handles: hidden/text/email/number inputs, checked checkboxes and radios,
    /// selected option in <select> dropdowns, and <textarea> content.
    func formFields(from html: String) -> [String: String] {
        var result: [String: String] = [:]

        // --- <input> tags ---
        for tag in matchStrings(#"<input\b[^>]*/?>"#, in: html) {
            guard let name = htmlAttr("name", in: tag), !name.isEmpty else { continue }
            let type_ = (htmlAttr("type", in: tag) ?? "text").lowercased()
            switch type_ {
            case "submit", "button", "image", "reset", "file":
                continue
            case "checkbox", "radio":
                let isChecked = tag.range(of: #"\bchecked\b"#,
                                          options: [.regularExpression, .caseInsensitive]) != nil
                if isChecked { result[name] = htmlAttr("value", in: tag) ?? "on" }
            default:
                result[name] = htmlAttr("value", in: tag) ?? ""
            }
        }

        // --- <select> tags: find currently-selected <option> ---
        for tag in matchStrings(#"<select\b[^>]*>[\s\S]*?</select>"#, in: html, multiline: true) {
            guard let name = htmlAttr("name", in: tag), !name.isEmpty else { continue }
            // <option ... selected ...> or <option ... selected="selected" ...>
            if let opt = matchStrings(#"<option\b[^>]*\bselected\b[^>]*>"#, in: tag).first {
                result[name] = htmlAttr("value", in: opt) ?? ""
            }
        }

        // --- <textarea> tags ---
        // Regex has 2 capture groups → matchGroups returns [fullMatch, attrs, content] (count == 3)
        for m in matchGroups(#"<textarea\b([^>]*)>([\s\S]*?)</textarea>"#, in: html, multiline: true) {
            guard m.count >= 3 else { continue }
            let attrString = m[1]
            guard let name = htmlAttr("name", in: "<textarea \(attrString)>"),
                  !name.isEmpty else { continue }
            result[name] = htmlUnescape(m[2])
        }

        return result
    }

    /// Extract song title from edit page HTML.
    /// Tries three strategies in order:
    /// 1. formFields["title"] — works for most songs
    /// 2. Any non-hidden <input> whose name ends with "title" — handles namespaced IDs
    /// 3. Any <textarea> whose name ends with "title" — some song statuses use textarea
    /// Returns "" if not found — blank is correct, wrong text is not.
    private func extractTitle(from html: String, fields: [String: String]) -> String {
        // Strategy 1: standard field lookup
        if let t = fields["title"], !t.isEmpty { return t }

        // Strategy 2: any visible input whose name ends in "title"
        for tag in matchStrings(#"<input\b[^>]*/?>"#, in: html) {
            guard let name = htmlAttr("name", in: tag),
                  name.lowercased().hasSuffix("title") else { continue }
            let type_ = (htmlAttr("type", in: tag) ?? "text").lowercased()
            guard type_ != "hidden" else { continue }
            if let val = htmlAttr("value", in: tag), !val.isEmpty { return val }
        }

        // Strategy 3: any textarea whose name ends in "title" (used on some song statuses)
        for m in matchGroups(#"<textarea\b([^>]*)>([\s\S]*?)</textarea>"#, in: html, multiline: true) {
            guard m.count >= 3 else { continue }
            let attrString = m[1]
            guard let name = htmlAttr("name", in: "<textarea \(attrString)>"),
                  name.lowercased().hasSuffix("title") else { continue }
            let val = htmlUnescape(m[2])
            if !val.isEmpty { return val }
        }

        return ""
    }

    /// Extract a named HTML attribute value (handles double- and single-quoted forms).
    private func htmlAttr(_ attr: String, in tag: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: attr)
        let patterns = ["\(escaped)=\"([^\"]*)\"", "\(escaped)='([^']*)'" ]
        for p in patterns {
            if let m = matchGroups(p, in: tag).first, m.count >= 2 {
                return htmlUnescape(m[1])
            }
        }
        return nil
    }

    private func htmlUnescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;",  with: "&")
         .replacingOccurrences(of: "&lt;",   with: "<")
         .replacingOccurrences(of: "&gt;",   with: ">")
         .replacingOccurrences(of: "&quot;", with: "\"")
         .replacingOccurrences(of: "&#39;",  with: "'")
         .replacingOccurrences(of: "&apos;", with: "'")
    }

    /// Find the `name` attribute of the first `<input>` with the given type.
    private func findField(type: String, in html: String) -> String? {
        for tag in matchStrings("<input\\b[^>]*\\btype=\"\(type)\"[^>]*>", in: html) {
            if let name = htmlAttr("name", in: tag) { return name }
        }
        return nil
    }

    /// Returns true if the shell page contains at least one stem set row in StemSetSection.
    private func hasStemSets(in html: String) -> Bool {
        guard let range = html.range(of: "StemSetSection", options: .caseInsensitive) else { return false }
        let sub = String(html[range.lowerBound...])
        guard let endRange = sub.range(of: "</div>") else { return false }
        let section = String(sub[sub.startIndex..<endRange.lowerBound])
        let allRows     = matchStrings(#"<tr\b"#, in: section)
        let headingRows = matchStrings(#"<tr\b[^>]*class="heading""#, in: section)
        return allRows.count > headingRows.count
    }

    private func findSubmitButton(in html: String) -> (String, String)? {
        for tag in matchStrings(#"<input\b[^>]*\btype="submit"[^>]*>"#, in: html) {
            if let name = htmlAttr("name", in: tag) {
                return (name, htmlAttr("value", in: tag) ?? "Submit")
            }
        }
        return nil
    }

    // MARK: - Value mappings

    private func keyID(for key: String) -> String {
        [
            "A": "1",  "Am": "2",  "Ab": "3",  "A#": "5",
            "B": "6",  "Bm": "7",  "Bb": "8",  "Bbm": "9",
            "C": "10", "Cm": "11", "C#": "13", "C#m": "14",
            "D": "15", "Dm": "16", "Db": "17", "D#": "19",
            "E": "20", "Em": "21", "Eb": "22", "Ebm": "23",
            "F": "24", "Fm": "25", "F#": "26", "F#m": "27",
            "G": "28", "Gm": "29", "Gb": "30", "G#": "31", "G#m": "32",
        ][key] ?? "0"
    }

    private func timeSigID(for sig: String) -> String {
        [
            "2/4":  "1",  "3/4":  "2",  "4/4":  "3",  "5/4":  "4",
            "6/4":  "5",  "7/4":  "6",  "9/4":  "7",  "10/4": "8",
            "11/4": "9",  "12/4": "10", "13/4": "11",
            "3/8":  "12", "6/8":  "13", "7/8":  "14", "9/8":  "15",
            "10/8": "16", "11/8": "17", "12/8": "18", "13/8": "19",
        ][sig] ?? "0"
    }

    private func formatBPM(_ bpm: String) -> String {
        Double(bpm).map { String(format: "%.2f", $0) } ?? bpm
    }

    private func statusLabel(for code: String) -> String {
        switch code {
        case "1":  return "Released"
        case "0":  return "Production"
        case "-1": return "Disabled"
        case "2":  return "New Purchases Disabled"
        case "3":  return "Content Holdback"
        default:   return ""
        }
    }

    // MARK: - Network helpers

    private func postMultipart(
        to url: URL,
        textFields: [String: String],
        fileField: String,
        fileData: Data,
        fileName: String,
        mimeType: String
    ) async throws -> (Data, URLResponse) {
        let boundary = "MTSTBoundary\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()

        func append(_ s: String) { body.append(Data(s.utf8)) }

        for (name, value) in textFields.sorted(by: { $0.key < $1.key }) {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(fileName)\"\r\n")
        append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(fileData)
        append("\r\n--\(boundary)--\r\n")

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(url.absoluteString, forHTTPHeaderField: "Referer")
        req.httpBody = body

        return try await session.data(for: req)
    }

    private func urlEncode(_ fields: [String: String]) -> Data {
        fields.map { k, v in
            "\(urlFormEncode(k))=\(urlFormEncode(v))"
        }.joined(separator: "&").data(using: .utf8) ?? Data()
    }

    /// Percent-encode a form value for application/x-www-form-urlencoded.
    /// Must NOT use .urlQueryAllowed — it leaves +, =, / unencoded, which
    /// corrupts ASP.NET base64 ViewState tokens (they contain all three chars).
    private func urlFormEncode(_ s: String) -> String {
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: cs) ?? s
    }

    private func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: - Regex utilities

    private func matchStrings(_ pattern: String, in text: String, multiline: Bool = false) -> [String] {
        var opts: NSRegularExpression.Options = [.caseInsensitive]
        if multiline { opts.insert(.dotMatchesLineSeparators) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private func matchGroups(_ pattern: String, in text: String, multiline: Bool = false) -> [[String]] {
        var opts: NSRegularExpression.Options = [.caseInsensitive]
        if multiline { opts.insert(.dotMatchesLineSeparators) }
        guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).map { m in
            (0..<m.numberOfRanges).map { i in
                Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
}
