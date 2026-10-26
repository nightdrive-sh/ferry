import Testing
@testable import FerryKit

let ages: [(Double, String)] = [(0, "now"), (59, "now"), (60, "1 min"), (3599, "59 min"), (3600, "1 h"), (86399, "23 h"),
                                 (86400, "1 d"), (3 * 86400 + 5, "3 d")]
let sizes: [(Int64, String)] = [(0, "0 B"), (240, "240 B"), (999, "999 B"), (1000, "1.0 KB"), (259_548, "259.5 KB"),
                                (5_700_000, "5.7 MB"), (999_999, "1000.0 KB"), (1_200_000_000, "1.2 GB"),
                                (4_000_000_000_000, "4000.0 GB")]

@Suite struct LabelsTests {
    @Test(arguments: ages)
    func ageShort(seconds: Double, label: String) {
        #expect(Age.short(seconds) == label)
    }

    @Test func ageOfTheFutureIsNow() {   // a computer's clock a little ahead of the phone's
        #expect(Age.short(-30) == "now")
    }

    @Test(arguments: sizes)
    func byteSize(bytes: Int64, label: String) {
        #expect(ByteSize.format(bytes) == label)
    }
}
