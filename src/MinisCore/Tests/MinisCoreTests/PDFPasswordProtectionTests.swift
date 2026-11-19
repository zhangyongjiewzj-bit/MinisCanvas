import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import MinisCore

@Suite("PDF password protection detection")
struct PDFPasswordProtectionTests {
    private func makePDF(userPassword: String?) throws -> Data {
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 64, height: 64)
        let consumer = try #require(CGDataConsumer(data: output as CFMutableData))
        var info: [CFString: Any] = [:]
        if let userPassword {
            info[kCGPDFContextUserPassword] = userPassword
            info[kCGPDFContextOwnerPassword] = userPassword + "-owner"
        }
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, info as CFDictionary))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return output as Data
    }

    @Test("a PDF that needs a password is reported as protected")
    func lockedPDFIsProtected() throws {
        #expect(MediaConversion.isPasswordProtectedPDF(try makePDF(userPassword: "secret")))
    }

    @Test("an ordinary PDF and non-PDF bytes are not reported as protected")
    func ordinaryPDFIsNotProtected() throws {
        #expect(!MediaConversion.isPasswordProtectedPDF(try makePDF(userPassword: nil)))
        #expect(!MediaConversion.isPasswordProtectedPDF(Data("not a pdf".utf8)))
    }
}
