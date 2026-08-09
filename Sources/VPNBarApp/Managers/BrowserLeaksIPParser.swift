import Foundation

/// Parses the server-rendered HTML of https://browserleaks.com/ip.
enum BrowserLeaksIPParser {
    struct Result: Equatable {
        let ip: String?
        let country: String?
        let countryCode: String?
        let city: String?
    }

    static func parse(_ html: String) -> Result? {
        let ip = firstMatch(in: html, pattern: #"id="client-ipv4"[^>]*data-ip="([^"]+)""#)
            ?? firstMatch(in: html, pattern: #"data-ip="([0-9a-fA-F:.]+)""#)
        let countryCode = firstMatch(in: html, pattern: #"id="client-ipv4"[^>]*data-iso_code="([A-Za-z]{2})""#)
            ?? firstMatch(in: html, pattern: #"id="lookup-flag"[^>]*data-iso_code="([A-Za-z]{2})""#)

        var country = firstMatch(
            in: html,
            pattern: #"id="lookup-flag"[^>]*>.*?<span class="flag-text[^"]*">\s*([^<]+?)\s*(?:<|$)"#
        )
        if let c = country {
            let trimmed = c.trimmingCharacters(in: .whitespacesAndNewlines)
            country = trimmed.isEmpty ? nil : trimmed
        }
        if country == nil {
            if let titled = firstMatch(
                in: html,
                pattern: #"id="lookup-flag"[^>]*>.*?<img[^>]*title="([^"(]+)""#
            ) {
                let trimmed = titled.trimmingCharacters(in: .whitespacesAndNewlines)
                country = trimmed.isEmpty ? nil : trimmed
            }
        }

        let cityRaw = firstMatch(in: html, pattern: #"<tr><td>City</td><td>([^<]*)</td></tr>"#)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let city = (cityRaw?.isEmpty == false) ? cityRaw : nil

        let result = Result(
            ip: ip,
            country: country,
            countryCode: countryCode?.uppercased(),
            city: city
        )
        return (result.ip != nil || result.country != nil || result.countryCode != nil) ? result : nil
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.dotMatchesLineSeparators, .caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[capture])
    }
}
