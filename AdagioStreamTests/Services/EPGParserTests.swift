import XCTest
@testable import AdagioStream

final class EPGParserTests: XCTestCase {

    func testParseSingleProgramme() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <programme start="20260227120000 +0000" stop="20260227130000 +0000" channel="ch1">
            <title>Morning Show</title>
            <desc>A great morning show.</desc>
          </programme>
        </tv>
        """

        let parser = EPGParser()
        let entries = try parser.parse(data: Data(xml.utf8))

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries["ch1"]?.count, 1)

        let entry = try XCTUnwrap(entries["ch1"]?.first)
        XCTAssertEqual(entry.channelID, "ch1")
        XCTAssertEqual(entry.title, "Morning Show")
        XCTAssertEqual(entry.description, "A great morning show.")
        XCTAssertEqual(entry.durationMinutes, 60)
    }

    func testParseMultipleProgrammesAcrossChannels() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <programme start="20260227100000 +0000" stop="20260227110000 +0000" channel="ch1">
            <title>Show A</title>
          </programme>
          <programme start="20260227110000 +0000" stop="20260227120000 +0000" channel="ch1">
            <title>Show B</title>
          </programme>
          <programme start="20260227100000 +0000" stop="20260227113000 +0000" channel="ch2">
            <title>Show C</title>
          </programme>
        </tv>
        """

        let parser = EPGParser()
        let entries = try parser.parse(data: Data(xml.utf8))

        XCTAssertEqual(entries["ch1"]?.count, 2)
        XCTAssertEqual(entries["ch2"]?.count, 1)
        XCTAssertEqual(entries["ch2"]?.first?.title, "Show C")
        XCTAssertEqual(entries["ch2"]?.first?.durationMinutes, 90)
    }

    func testMissingDescriptionIsNil() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <programme start="20260227120000 +0000" stop="20260227130000 +0000" channel="ch1">
            <title>No Desc Show</title>
          </programme>
        </tv>
        """

        let parser = EPGParser()
        let entries = try parser.parse(data: Data(xml.utf8))

        let entry = try XCTUnwrap(entries["ch1"]?.first)
        XCTAssertNil(entry.description)
    }

    func testMissingDatesSkipsEntry() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <programme channel="ch1">
            <title>No Dates</title>
          </programme>
          <programme start="20260227120000 +0000" stop="20260227130000 +0000" channel="ch1">
            <title>Valid Show</title>
          </programme>
        </tv>
        """

        let parser = EPGParser()
        let entries = try parser.parse(data: Data(xml.utf8))

        XCTAssertEqual(entries["ch1"]?.count, 1)
        XCTAssertEqual(entries["ch1"]?.first?.title, "Valid Show")
    }

    func testGroupingByChannelID() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv>
          <programme start="20260227100000 +0000" stop="20260227110000 +0000" channel="news">
            <title>News at 10</title>
          </programme>
          <programme start="20260227110000 +0000" stop="20260227120000 +0000" channel="sports">
            <title>Game Time</title>
          </programme>
          <programme start="20260227120000 +0000" stop="20260227130000 +0000" channel="news">
            <title>Noon Report</title>
          </programme>
        </tv>
        """

        let parser = EPGParser()
        let entries = try parser.parse(data: Data(xml.utf8))

        XCTAssertEqual(entries.keys.count, 2)
        XCTAssertEqual(entries["news"]?.count, 2)
        XCTAssertEqual(entries["sports"]?.count, 1)
    }
}
