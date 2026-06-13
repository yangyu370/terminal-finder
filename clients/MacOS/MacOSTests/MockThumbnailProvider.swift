import AppKit
@testable import MacOS

final class MockThumbnailProvider: ThumbnailProviding {
    struct Request {
        let descriptor: ThumbnailDescriptor
        let completion: (NSImage?) -> Void
        let token: MockThumbnailRequestToken
    }

    var cachedImages: [ThumbnailDescriptor: NSImage] = [:]
    private(set) var requests: [Request] = []

    func cachedThumbnail(for descriptor: ThumbnailDescriptor) -> NSImage? {
        cachedImages[descriptor]
    }

    @discardableResult
    func thumbnail(
        for descriptor: ThumbnailDescriptor,
        completion: @escaping (NSImage?) -> Void
    ) -> ThumbnailRequestToken {
        let token = MockThumbnailRequestToken()
        requests.append(Request(descriptor: descriptor, completion: completion, token: token))
        return token
    }

    func completeRequest(at index: Int, image: NSImage?) {
        requests[index].completion(image)
    }
}

final class MockThumbnailRequestToken: ThumbnailRequestToken {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}
