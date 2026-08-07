import Testing
@testable import MacCleanerCore

@Suite("SizeFormatter Tests")
struct SizeFormatterTests {

    @Test("Formats zero bytes")
    func formatsZero() {
        #expect(SizeFormatter.format(bytes: 0) == "0 B")
    }

    @Test("Formats bytes")
    func formatsBytes() {
        #expect(SizeFormatter.format(bytes: 500) == "500 B")
    }

    @Test("Formats kilobytes")
    func formatsKB() {
        #expect(SizeFormatter.format(bytes: 1024) == "1.00 KB")
        #expect(SizeFormatter.format(bytes: 10240) == "10.0 KB")
    }

    @Test("Formats megabytes")
    func formatsMB() {
        #expect(SizeFormatter.format(bytes: 1048576) == "1.00 MB")
        #expect(SizeFormatter.format(bytes: 524288000) == "500 MB")
    }

    @Test("Formats gigabytes")
    func formatsGB() {
        #expect(SizeFormatter.format(bytes: 1073741824) == "1.00 GB")
        #expect(SizeFormatter.format(bytes: 12884901888) == "12.0 GB")
    }

    @Test("Int64 extension works")
    func int64Extension() {
        let size: Int64 = 1073741824
        #expect(size.formattedSize == "1.00 GB")
    }
}
