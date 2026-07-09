import Foundation

/// Minimal RFC 4918 multistatus reader: each <response>'s href + whether its resourcetype
/// marks a collection. Namespace-agnostic via shouldProcessNamespaces — OpenCloud,
/// Nextcloud, and Apache mod_dav all prefix DAV: differently, and local names + namespace
/// URI are the only stable coordinates. Malformed XML degrades to whatever parsed before
/// the error (garbage → empty) — callers treat it as "nothing listed", best-effort.
enum WebDAVMultistatus {
    struct Entry: Equatable, Sendable {
        let href: String        // percent-decoded server path
        let isCollection: Bool
    }

    static func parse(_ data: Data) -> [Entry] {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = reader
        parser.parse()
        return reader.entries
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        private var href = ""
        private var inHref = false
        private var isCollection = false

        func parser(
            _ parser: XMLParser, didStartElement elementName: String,
            namespaceURI: String?, qualifiedName: String?,
            attributes attributeDict: [String: String]
        ) {
            guard namespaceURI == "DAV:" else { return }
            switch elementName {
            case "response": href = ""; isCollection = false
            case "href": inHref = true
            case "collection": isCollection = true
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inHref { href += string }
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String,
            namespaceURI: String?, qualifiedName: String?
        ) {
            guard namespaceURI == "DAV:" else { return }
            switch elementName {
            case "href":
                inHref = false
            case "response":
                let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
                entries.append(Entry(
                    href: trimmed.removingPercentEncoding ?? trimmed,
                    isCollection: isCollection))
            default: break
            }
        }
    }
}
