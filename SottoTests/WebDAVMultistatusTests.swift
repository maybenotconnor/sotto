import Foundation
import Testing
@testable import Sotto

struct WebDAVMultistatusTests {
    /// OpenCloud/Nextcloud (sabre) shape: `d:` prefix for DAV:.
    private let sabreStyle = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
      <d:response>
        <d:href>/remote.php/dav/files/connor/Sotto/</d:href>
        <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
        <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
      </d:response>
      <d:response>
        <d:href>/remote.php/dav/files/connor/Sotto/2026-07-07/</d:href>
        <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop>
        <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
      </d:response>
      <d:response>
        <d:href>/remote.php/dav/files/connor/Sotto/notes.txt</d:href>
        <d:propstat><d:prop><d:resourcetype/></d:prop>
        <d:status>HTTP/1.1 200 OK</d:status></d:propstat>
      </d:response>
    </d:multistatus>
    """

    /// Apache mod_dav shape: `D:` prefix — same DAV: namespace.
    private let modDavStyle = """
    <?xml version="1.0" encoding="utf-8"?>
    <D:multistatus xmlns:D="DAV:">
      <D:response>
        <D:href>/dav/Sotto/2026-07-08/</D:href>
        <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
      </D:response>
      <D:response>
        <D:href>/dav/Sotto/2026-07-08/10-30-00.md</D:href>
        <D:propstat><D:prop><D:resourcetype/></D:prop>
        <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
      </D:response>
    </D:multistatus>
    """

    @Test func parsesHrefsAndCollectionFlags() {
        let entries = WebDAVMultistatus.parse(Data(sabreStyle.utf8))
        #expect(entries == [
            .init(href: "/remote.php/dav/files/connor/Sotto/", isCollection: true),
            .init(href: "/remote.php/dav/files/connor/Sotto/2026-07-07/", isCollection: true),
            .init(href: "/remote.php/dav/files/connor/Sotto/notes.txt", isCollection: false),
        ])
    }

    @Test func namespacePrefixDoesNotMatter() {
        let entries = WebDAVMultistatus.parse(Data(modDavStyle.utf8))
        #expect(entries.count == 2)
        #expect(entries[0].isCollection == true)
        #expect(entries[1].href == "/dav/Sotto/2026-07-08/10-30-00.md")
        #expect(entries[1].isCollection == false)
    }

    @Test func hrefsArePercentDecoded() {
        let xml = """
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:"><d:response>
          <d:href>/dav/My%20Files/2026-07-07/</d:href>
          <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat>
        </d:response></d:multistatus>
        """
        #expect(WebDAVMultistatus.parse(Data(xml.utf8)).first?.href == "/dav/My Files/2026-07-07/")
    }

    @Test func garbageParsesToEmpty() {
        #expect(WebDAVMultistatus.parse(Data("not xml at all".utf8)).isEmpty)
    }
}
