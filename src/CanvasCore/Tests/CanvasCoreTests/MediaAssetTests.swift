import Foundation
import Testing
@testable import CanvasCore

struct MediaAssetTests {
    @Test func mediaAssetCodableRoundTripPreservesIdentityAndSource() throws {
        let parentID = UUID()
        let asset = MediaAsset(
            kind: .image,
            source: .derived(parentID: parentID),
            status: .ready,
            localURL: "/tmp/image.png",
            remoteURL: "https://example.invalid/image.png",
            sourceCanvasID: UUID(),
            version: 3,
            metadata: ["name": "cover"]
        )

        let data = try JSONEncoder().encode(asset)
        let decoded = try JSONDecoder().decode(MediaAsset.self, from: data)

        #expect(decoded == asset)
        #expect(decoded.source == .derived(parentID: parentID))
    }

    @Test func mediaValueCarriesOnlyTypedAssetReference() throws {
        let value = MediaValue(assetID: UUID(), kind: .video)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(MediaValue.self, from: data)

        #expect(decoded == value)
        #expect(decoded.kind == .video)
    }

    @Test func malformedSourceFailsWithoutFallback() {
        let data = Data(#"{"id":"00000000-0000-0000-0000-000000000001","kind":"image","source":{"kind":"derived"},"status":"ready","version":1,"createdAt":0,"updatedAt":0,"metadata":{}}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(MediaAsset.self, from: data)
        }
    }

    @Test func mediaValueRejectsDuplicateAssetIDs() throws {
        let assetID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
        let first = MediaAsset(id: assetID, kind: .image, source: .imported, localURL: "/tmp/first.png")
        let duplicate = MediaAsset(id: assetID, kind: .image, source: .imported, localURL: "/tmp/second.png")

        #expect(throws: CanvasSchemaError.invalidField("media.assets.ids")) {
            try MediaValue.assets([first, duplicate]).validate()
        }
    }
}
