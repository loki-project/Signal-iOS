//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit

@objc
public enum LinkPreviewError: Int, Error {
    case invalidInput
    case noPreview
    case assertionFailure
    case couldNotDownload
    case featureDisabled
    case invalidContent
    case invalidMediaContent
    case attachmentFailedToSave
}

// MARK: - OWSLinkPreviewDraft

public class OWSLinkPreviewContents: NSObject {
    @objc
    public var title: String?

    @objc
    public var imageUrl: String?

    public init(title: String?, imageUrl: String? = nil) {
        self.title = title
        self.imageUrl = imageUrl

        super.init()
    }
}

// This contains the info for a link preview "draft".
public class OWSLinkPreviewDraft: NSObject {
    @objc
    public var urlString: String

    @objc
    public var title: String?

    @objc
    public var jpegImageData: Data?

    public init(urlString: String, title: String?, jpegImageData: Data? = nil) {
        self.urlString = urlString
        self.title = title
        self.jpegImageData = jpegImageData

        super.init()
    }

    fileprivate func isValid() -> Bool {
        var hasTitle = false
        if let titleValue = title {
            hasTitle = titleValue.count > 0
        }
        let hasImage = jpegImageData != nil
        return hasTitle || hasImage
    }

    @objc
    public func displayDomain() -> String? {
        return OWSLinkPreview.displayDomain(forUrl: urlString)
    }
}

// MARK: - OWSLinkPreview

@objc
public class OWSLinkPreview: MTLModel {
    @objc
    public static let featureEnabled = true

    @objc
    public var urlString: String?

    @objc
    public var title: String?

    @objc
    public var imageAttachmentId: String?
    
    // Whether this preview can be rendered as an attachment
    @objc
    public var isDirectAttachment: Bool = false

    @objc
    public init(urlString: String, title: String?, imageAttachmentId: String?, isDirectAttachment: Bool = false) {
        self.urlString = urlString
        self.title = title
        self.imageAttachmentId = imageAttachmentId
        self.isDirectAttachment = isDirectAttachment

        super.init()
    }

    @objc
    public override init() {
        super.init()
    }

    @objc
    public required init!(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc
    public required init(dictionary dictionaryValue: [String: Any]!) throws {
        try super.init(dictionary: dictionaryValue)
    }

    @objc
    public class func isNoPreviewError(_ error: Error) -> Bool {
        guard let error = error as? LinkPreviewError else {
            return false
        }
        return error == .noPreview
    }
    
    @objc
    public class func isInvalidContentError(_ error: Error) -> Bool {
        guard let error = error as? LinkPreviewError else { return false }
        return error == .invalidContent
    }

    @objc
    public class func buildValidatedLinkPreview(dataMessage: SSKProtoDataMessage,
                                                body: String?,
                                                transaction: YapDatabaseReadWriteTransaction) throws -> OWSLinkPreview {
        guard OWSLinkPreview.featureEnabled else {
            throw LinkPreviewError.noPreview
        }
        guard let previewProto = dataMessage.preview.first else {
            throw LinkPreviewError.noPreview
        }
        guard dataMessage.attachments.count < 1 else {
            Logger.error("Discarding link preview; message has attachments.")
            throw LinkPreviewError.invalidInput
        }
        let urlString = previewProto.url

        guard URL(string: urlString) != nil else {
            Logger.error("Could not parse preview URL.")
            throw LinkPreviewError.invalidInput
        }

        guard let body = body else {
            Logger.error("Preview for message without body.")
            throw LinkPreviewError.invalidInput
        }
        let previewUrls = allPreviewUrls(forMessageBodyText: body)
        guard previewUrls.contains(urlString) else {
            Logger.error("URL not present in body.")
            throw LinkPreviewError.invalidInput
        }

        guard isValidLinkUrl(urlString) else {
            Logger.verbose("Invalid link URL \(urlString).")
            Logger.error("Invalid link URL.")
            throw LinkPreviewError.invalidInput
        }

        var title: String?
        if let rawTitle = previewProto.title {
            let normalizedTitle = OWSLinkPreview.normalizeTitle(title: rawTitle)
            if normalizedTitle.count > 0 {
                title = normalizedTitle
            }
        }
        
        var imageAttachmentId: String?
        if let imageProto = previewProto.image {
            if let imageAttachmentPointer = TSAttachmentPointer(fromProto: imageProto, albumMessage: nil) {
                imageAttachmentPointer.save(with: transaction)
                imageAttachmentId = imageAttachmentPointer.uniqueId
            } else {
                Logger.error("Could not parse image proto.")
                throw LinkPreviewError.invalidInput
            }
        }

        let linkPreview = OWSLinkPreview(urlString: urlString, title: title, imageAttachmentId: imageAttachmentId)

        guard linkPreview.isValid() else {
            Logger.error("Preview has neither title nor image.")
            throw LinkPreviewError.invalidInput
        }

        return linkPreview
    }

    @objc
    public class func buildValidatedLinkPreview(fromInfo info: OWSLinkPreviewDraft,
                                                transaction: YapDatabaseReadWriteTransaction) throws -> OWSLinkPreview {
        guard OWSLinkPreview.featureEnabled else {
            throw LinkPreviewError.noPreview
        }
        guard SSKPreferences.areLinkPreviewsEnabled else {
            throw LinkPreviewError.noPreview
        }
        let imageAttachmentId = OWSLinkPreview.saveAttachmentIfPossible(jpegImageData: info.jpegImageData,
                                                                        transaction: transaction)

        let linkPreview = OWSLinkPreview(urlString: info.urlString, title: info.title, imageAttachmentId: imageAttachmentId)

        guard linkPreview.isValid() else {
            owsFailDebug("Preview has neither title nor image.")
            throw LinkPreviewError.invalidInput
        }

        return linkPreview
    }
    
    private class func saveAttachmentIfPossible(jpegImageData: Data?,
                                                transaction: YapDatabaseReadWriteTransaction) -> String? {
        return saveAttachmentIfPossible(imageData: jpegImageData, mimeType: OWSMimeTypeImageJpeg, transaction: transaction);
    }
    
    private class func saveAttachmentIfPossible(imageData: Data?, mimeType: String, transaction: YapDatabaseReadWriteTransaction) -> String? {
        guard let imageData = imageData else { return nil }
        
        let fileSize = imageData.count
        guard fileSize > 0 else {
            owsFailDebug("Invalid file size for image data.")
            return nil
        }
        
        guard let fileExtension = fileExtension(forMimeType: mimeType) else { return nil }
        let filePath = OWSFileSystem.temporaryFilePath(withFileExtension: fileExtension)
        do {
            try imageData.write(to: NSURL.fileURL(withPath: filePath), options: .atomicWrite)
        } catch let error as NSError {
            owsFailDebug("file write failed: \(filePath), \(error)")
            return nil
        }
        
        guard let dataSource = DataSourcePath.dataSource(withFilePath: filePath, shouldDeleteOnDeallocation: true) else {
            owsFailDebug("Could not create data source for path: \(filePath)")
            return nil
        }
        let attachment = TSAttachmentStream(contentType: mimeType, byteCount: UInt32(fileSize), sourceFilename: nil, caption: nil, albumMessageId: nil)
        guard attachment.write(dataSource) else {
            owsFailDebug("Could not write data source for path: \(filePath)")
            return nil
        }
        attachment.save(with: transaction)

        return attachment.uniqueId
    }

    private func isValid() -> Bool {
        var hasTitle = false
        if let titleValue = title {
            hasTitle = titleValue.count > 0
        }
        let hasImage = imageAttachmentId != nil
        return hasTitle || hasImage
    }

    @objc
    public func removeAttachment(transaction: YapDatabaseReadWriteTransaction) {
        guard let imageAttachmentId = imageAttachmentId else {
            owsFailDebug("No attachment id.")
            return
        }
        guard let attachment = TSAttachment.fetch(uniqueId: imageAttachmentId, transaction: transaction) else {
            owsFailDebug("Could not load attachment.")
            return
        }
        attachment.remove(with: transaction)
    }

    private class func normalizeTitle(title: String) -> String {
        var result = title
        // Truncate title after 2 lines of text.
        let maxLineCount = 2
        var components = result.components(separatedBy: .newlines)
        if components.count > maxLineCount {
            components = Array(components[0..<maxLineCount])
            result =  components.joined(separator: "\n")
        }
        let maxCharacterCount = 2048
        if result.count > maxCharacterCount {
            let endIndex = result.index(result.startIndex, offsetBy: maxCharacterCount)
            result = String(result[..<endIndex])
        }
        return result.filterStringForDisplay()
    }

    // MARK: - Whitelists

    // For link domains, we require an exact match - no subdomains allowed.
    //
    // Note that order matters in this whitelist since the logic for determining
    // how to render link preview domains in displayDomain(...) uses the first match.
    // We should list TLDs first and subdomains later.
    private static let linkDomainWhitelist = [
        // YouTube
        "youtube.com",
        "www.youtube.com",
        "m.youtube.com",
        "youtu.be",

        // Reddit
        "reddit.com",
        "www.reddit.com",
        "m.reddit.com",
        // NOTE: We don't use redd.it.

        // Imgur
        //
        // NOTE: Subdomains are also used for content.
        //
        // For example, you can access "user/member" pages: https://sillygoose2.imgur.com/
        // A different member page can be accessed without a subdomain: https://imgur.com/user/SillyGoose2
        //
        // I'm not sure we need to support these subdomains; they don't appear to be core functionality.
        "imgur.com",
        "www.imgur.com",
        "m.imgur.com",

        // Instagram
        "instagram.com",
        "www.instagram.com",
        "m.instagram.com",

        // Pinterest
        "pinterest.com",
        "www.pinterest.com",
        "pin.it",
        
        // Giphy
        "giphy.com",
        "media.giphy.com",
        "media1.giphy.com",
        "media2.giphy.com",
        "media3.giphy.com",
        "gph.is"
    ]

    // For media domains, we DO NOT require an exact match - subdomains are allowed.
    private static let mediaDomainWhitelist = [
        // YouTube
        "ytimg.com",

        // Reddit
        "redd.it",

        // Imgur
        "imgur.com",

        // Instagram
        "cdninstagram.com",
        "fbcdn.net",

        // Pinterest
        "pinimg.com",
        
        // Giphy
        "giphy.com"
    ]

    private static let protocolWhitelist = [
        "https"
    ]

    @objc
    public func displayDomain() -> String? {
        return OWSLinkPreview.displayDomain(forUrl: urlString)
    }

    @objc
    public class func displayDomain(forUrl urlString: String?) -> String? {
        guard let urlString = urlString else {
            owsFailDebug("Missing url.")
            return nil
        }
        guard let url = URL(string: urlString) else {
            owsFailDebug("Invalid url.")
            return nil
        }
        guard let result = whitelistedDomain(forUrl: url,
                                             domainWhitelist: OWSLinkPreview.linkDomainWhitelist,
                                             allowSubdomains: false) else {
                                                Logger.error("Missing domain.")
                                                return nil
        }
        return result
    }

    @objc
    public class func isValidLinkUrl(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else {
            return false
        }
        return whitelistedDomain(forUrl: url,
                                 domainWhitelist: OWSLinkPreview.linkDomainWhitelist,
                                 allowSubdomains: false) != nil
    }

    @objc
    public class func isValidMediaUrl(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else {
            return false
        }
        return whitelistedDomain(forUrl: url,
                                 domainWhitelist: OWSLinkPreview.mediaDomainWhitelist,
                                 allowSubdomains: true) != nil
    }

    private class func whitelistedDomain(forUrl url: URL, domainWhitelist: [String], allowSubdomains: Bool) -> String? {
        guard let urlProtocol = url.scheme?.lowercased() else {
            return nil
        }
        guard protocolWhitelist.contains(urlProtocol) else {
            return nil
        }
        guard let domain = url.host?.lowercased() else {
            return nil
        }
        guard url.path.count > 1 else {
            // URL must have non-empty path.
            return nil
        }

        for whitelistedDomain in domainWhitelist {
            if domain == whitelistedDomain.lowercased() {
                return whitelistedDomain
            }
            if allowSubdomains,
                domain.hasSuffix("." + whitelistedDomain.lowercased()) {
                return whitelistedDomain
            }
        }
        return nil
    }

    // MARK: - Serial Queue

    private static let serialQueue = DispatchQueue(label: "org.signal.linkPreview")

    private class func assertIsOnSerialQueue() {
        if _isDebugAssertConfiguration(), #available(iOS 10.0, *) {
            assertOnQueue(serialQueue)
        }
    }

    // MARK: - Text Parsing

    // This cache should only be accessed on main thread.
    private static var previewUrlCache: NSCache<NSString, NSString> = NSCache()

    @objc
    public class func previewUrl(forRawBodyText body: String?, selectedRange: NSRange) -> String? {
        return previewUrl(forMessageBodyText: body, selectedRange: selectedRange)
    }

    @objc
    public class func previewURL(forRawBodyText body: String?) -> String? {
        return previewUrl(forMessageBodyText: body, selectedRange: nil)
    }

    public class func previewUrl(forMessageBodyText body: String?, selectedRange: NSRange?) -> String? {
        AssertIsOnMainThread()

        // Exit early if link previews are not enabled in order to avoid
        // tainting the cache.
        guard OWSLinkPreview.featureEnabled else {
            return nil
        }

        guard SSKPreferences.areLinkPreviewsEnabled else {
            return nil
        }

        guard let body = body else {
            return nil
        }

        if let cachedUrl = previewUrlCache.object(forKey: body as NSString) as String? {
            Logger.verbose("URL parsing cache hit.")
            guard cachedUrl.count > 0 else {
                return nil
            }
            return cachedUrl
        }
        let previewUrlMatches = allPreviewUrlMatches(forMessageBodyText: body)
        guard let urlMatch = previewUrlMatches.first else {
            // Use empty string to indicate "no preview URL" in the cache.
            previewUrlCache.setObject("", forKey: body as NSString)
            return nil
        }

        if let selectedRange = selectedRange {
            Logger.verbose("match: urlString: \(urlMatch.urlString) range: \(urlMatch.matchRange) selectedRange: \(selectedRange)")
            let cursorAtEndOfMatch = urlMatch.matchRange.location + urlMatch.matchRange.length == selectedRange.location
            if selectedRange.location != body.count,
                (urlMatch.matchRange.intersection(selectedRange) != nil || cursorAtEndOfMatch) {
                Logger.debug("ignoring URL, since the user is currently editing it.")
                // we don't want to cache the result here, as we want to fetch the link preview
                // if the user moves the cursor.
                return nil
            }
            Logger.debug("considering URL, since the user is not currently editing it.")
        }

        previewUrlCache.setObject(urlMatch.urlString as NSString, forKey: body as NSString)
        return urlMatch.urlString
    }

    struct URLMatchResult {
        let urlString: String
        let matchRange: NSRange
    }

    class func allPreviewUrls(forMessageBodyText body: String) -> [String] {
        return allPreviewUrlMatches(forMessageBodyText: body).map { $0.urlString }
    }

    class func allPreviewUrlMatches(forMessageBodyText body: String) -> [URLMatchResult] {
        guard OWSLinkPreview.featureEnabled else {
            return []
        }
        guard SSKPreferences.areLinkPreviewsEnabled else {
            return []
        }

        let detector: NSDataDetector
        do {
            detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        } catch {
            owsFailDebug("Could not create NSDataDetector: \(error).")
            return []
        }

        var urlMatches: [URLMatchResult] = []
        let matches = detector.matches(in: body, options: [], range: NSRange(location: 0, length: body.count))
        for match in matches {
            guard let matchURL = match.url else {
                owsFailDebug("Match missing url")
                continue
            }
            let urlString = matchURL.absoluteString
            if isValidLinkUrl(urlString) {
                let matchResult = URLMatchResult(urlString: urlString, matchRange: match.range)
                urlMatches.append(matchResult)
            }
        }
        return urlMatches
    }

    // MARK: - Preview Construction

    // This cache should only be accessed on serialQueue.
    //
    // We should only maintain a "cache" of the last known draft.
    private static var linkPreviewDraftCache: OWSLinkPreviewDraft?

    private class func cachedLinkPreview(forPreviewUrl previewUrl: String) -> OWSLinkPreviewDraft? {
        return serialQueue.sync {
            guard let linkPreviewDraft = linkPreviewDraftCache,
                linkPreviewDraft.urlString == previewUrl else {
                    Logger.verbose("----- Cache miss.")
                return nil
            }
            Logger.verbose("----- Cache hit.")
            return linkPreviewDraft
        }
    }

    private class func setCachedLinkPreview(_ linkPreviewDraft: OWSLinkPreviewDraft,
                                            forPreviewUrl previewUrl: String) {
        assert(previewUrl == linkPreviewDraft.urlString)

        // Exit early if link previews are not enabled in order to avoid
        // tainting the cache.
        guard OWSLinkPreview.featureEnabled else {
            return
        }
        guard SSKPreferences.areLinkPreviewsEnabled else {
            return
        }

        serialQueue.sync {
            linkPreviewDraftCache = linkPreviewDraft
        }
    }

    @objc
    public class func tryToBuildPreviewInfoObjc(previewUrl: String?) -> AnyPromise {
        return AnyPromise(tryToBuildPreviewInfo(previewUrl: previewUrl))
    }

    public class func tryToBuildPreviewInfo(previewUrl: String?) -> Promise<OWSLinkPreviewDraft> {
        guard OWSLinkPreview.featureEnabled else {
            return Promise(error: LinkPreviewError.featureDisabled)
        }
        guard SSKPreferences.areLinkPreviewsEnabled else {
            return Promise(error: LinkPreviewError.featureDisabled)
        }
        guard let previewUrl = previewUrl else {
            return Promise(error: LinkPreviewError.invalidInput)
        }
        if let cachedInfo = cachedLinkPreview(forPreviewUrl: previewUrl) {
            Logger.verbose("Link preview info cache hit.")
            return Promise.value(cachedInfo)
        }
        return downloadLink(url: previewUrl)
            .then(on: DispatchQueue.global()) { (data) -> Promise<OWSLinkPreviewDraft> in
                return parseLinkDataAndBuildDraft(linkData: data, linkUrlString: previewUrl)
            }.then(on: DispatchQueue.global()) { (linkPreviewDraft) -> Promise<OWSLinkPreviewDraft> in
                guard linkPreviewDraft.isValid() else {
                    throw LinkPreviewError.noPreview
                }
                setCachedLinkPreview(linkPreviewDraft, forPreviewUrl: previewUrl)

                return Promise.value(linkPreviewDraft)
        }
    }

    class func downloadLink(url urlString: String,
                            remainingRetries: UInt = 3) -> Promise<Data> {

        Logger.verbose("url: \(urlString)")

        // let sessionConfiguration = ContentProxy.sessionConfiguration() // Loki: Signal's proxy appears to have been banned by YouTube
        let sessionConfiguration = URLSessionConfiguration.ephemeral

        // Don't use any caching to protect privacy of these requests.
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.urlCache = nil

        let sessionManager = AFHTTPSessionManager(baseURL: nil,
                                                  sessionConfiguration: sessionConfiguration)
        sessionManager.requestSerializer = AFHTTPRequestSerializer()
        sessionManager.responseSerializer = AFHTTPResponseSerializer()

        guard ContentProxy.configureSessionManager(sessionManager: sessionManager, forUrl: urlString) else {
            owsFailDebug("Could not configure url: \(urlString).")
            return Promise(error: LinkPreviewError.assertionFailure)
        }

        let (promise, resolver) = Promise<Data>.pending()
        sessionManager.get(urlString,
                           parameters: [String: AnyObject](),
                           headers: nil,
                           progress: nil,
                           success: { task, value in

                            guard let response = task.response as? HTTPURLResponse else {
                                Logger.warn("Invalid response: \(type(of: task.response)).")
                                resolver.reject(LinkPreviewError.assertionFailure)
                                return
                            }
                            if let contentType = response.allHeaderFields["Content-Type"] as? String {
                                guard contentType.lowercased().hasPrefix("text/") else {
                                    Logger.warn("Invalid content type: \(contentType).")
                                    resolver.reject(LinkPreviewError.invalidContent)
                                    return
                                }
                            }
                            guard let data = value as? Data else {
                                Logger.warn("Result is not data: \(type(of: value)).")
                                resolver.reject(LinkPreviewError.assertionFailure)
                                return
                            }
                            guard data.count > 0 else {
                                Logger.warn("Empty data: \(type(of: value)).")
                                resolver.reject(LinkPreviewError.invalidContent)
                                return
                            }
                            resolver.fulfill(data)
        },
                           failure: { _, error in
                            Logger.verbose("Error: \(error)")

                            guard isRetryable(error: error) else {
                                Logger.warn("Error is not retryable.")
                                resolver.reject(LinkPreviewError.couldNotDownload)
                                return
                            }

                            guard remainingRetries > 0 else {
                                Logger.warn("No more retries.")
                                resolver.reject(LinkPreviewError.couldNotDownload)
                                return
                            }
                            OWSLinkPreview.downloadLink(url: urlString, remainingRetries: remainingRetries - 1)
                            .done(on: DispatchQueue.global()) { (data) in
                                resolver.fulfill(data)
                            }.catch(on: DispatchQueue.global()) { (error) in
                                resolver.reject(error)
                            }.retainUntilComplete()
        })
        return promise
    }

    private class func downloadImage(url urlString: String, imageMimeType: String) -> Promise<Data> {

        Logger.verbose("url: \(urlString)")

        guard let url = URL(string: urlString) else {
            Logger.error("Could not parse URL.")
            return Promise(error: LinkPreviewError.invalidInput)
        }

        guard let assetDescription = ProxiedContentAssetDescription(url: url as NSURL) else {
            Logger.error("Could not create asset description.")
            return Promise(error: LinkPreviewError.invalidInput)
        }
        let (promise, resolver) = Promise<ProxiedContentAsset>.pending()
        DispatchQueue.main.async {
            _ = ProxiedContentDownloader.defaultDownloader.requestAsset(assetDescription: assetDescription,
                                                                        priority: .high,
                                                                        success: { (_, asset) in
                                                                            resolver.fulfill(asset)
            }, failure: { (_) in
                Logger.warn("Error downloading asset")
                resolver.reject(LinkPreviewError.couldNotDownload)
            })
        }
        return promise.then(on: DispatchQueue.global()) { (asset: ProxiedContentAsset) -> Promise<Data> in
            do {
                let imageSize = NSData.imageSize(forFilePath: asset.filePath, mimeType: imageMimeType)
                guard imageSize.width > 0, imageSize.height > 0 else {
                    Logger.error("Link preview is invalid or has invalid size.")
                    return Promise(error: LinkPreviewError.invalidContent)
               }
                let data = try Data(contentsOf: URL(fileURLWithPath: asset.filePath))

                guard let srcImage = UIImage(data: data) else {
                    Logger.error("Could not parse image.")
                    return Promise(error: LinkPreviewError.invalidContent)
                }
                
                // Loki: If it's a GIF then ensure its validity and don't download it as a JPG
                if (imageMimeType == OWSMimeTypeImageGif && NSData(data: data).ows_isValidImage(withMimeType: OWSMimeTypeImageGif)) { return Promise.value(data) }

                let maxImageSize: CGFloat = 1024
                let shouldResize = imageSize.width > maxImageSize || imageSize.height > maxImageSize
                guard shouldResize else {
                    guard let dstData = srcImage.jpegData(compressionQuality: 0.8) else {
                        Logger.error("Could not write resized image.")
                        return Promise(error: LinkPreviewError.invalidContent)
                    }
                    return Promise.value(dstData)
                }

                guard let dstImage = srcImage.resized(withMaxDimensionPoints: maxImageSize) else {
                    Logger.error("Could not resize image.")
                    return Promise(error: LinkPreviewError.invalidContent)
                }
                guard let dstData = dstImage.jpegData(compressionQuality: 0.8) else {
                    Logger.error("Could not write resized image.")
                    return Promise(error: LinkPreviewError.invalidContent)
                }
                return Promise.value(dstData)
            } catch {
                owsFailDebug("Could not load asset data: \(type(of: asset.filePath)).")
                return Promise(error: LinkPreviewError.assertionFailure)
            }
        }
    }

    private class func isRetryable(error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == kCFErrorDomainCFNetwork as String {
            // Network failures are retried.
            return true
        }
        return false
    }

    class func parseLinkDataAndBuildDraft(linkData: Data,
                                          linkUrlString: String) -> Promise<OWSLinkPreviewDraft> {
        do {
            let contents = try parse(linkData: linkData)

            let title = contents.title
            guard let imageUrl = contents.imageUrl else {
                return Promise.value(OWSLinkPreviewDraft(urlString: linkUrlString, title: title))
            }

            guard isValidMediaUrl(imageUrl) else {
                Logger.error("Invalid image URL.")
                return Promise.value(OWSLinkPreviewDraft(urlString: linkUrlString, title: title))
            }
            guard let imageFileExtension = fileExtension(forImageUrl: imageUrl) else {
                Logger.error("Image URL has unknown or invalid file extension: \(imageUrl).")
                return Promise.value(OWSLinkPreviewDraft(urlString: linkUrlString, title: title))
            }
            guard let imageMimeType = mimetype(forImageFileExtension: imageFileExtension) else {
                Logger.error("Image URL has unknown or invalid content type: \(imageUrl).")
                return Promise.value(OWSLinkPreviewDraft(urlString: linkUrlString, title: title))
            }

            return downloadImage(url: imageUrl, imageMimeType: imageMimeType)
                .map(on: DispatchQueue.global()) { (imageData: Data) -> OWSLinkPreviewDraft in
                    // We always recompress images to Jpeg.
                    let linkPreviewDraft = OWSLinkPreviewDraft(urlString: linkUrlString, title: title, jpegImageData: imageData)
                    return linkPreviewDraft
                }
                .recover(on: DispatchQueue.global()) { (_) -> Promise<OWSLinkPreviewDraft> in
                    return Promise.value(OWSLinkPreviewDraft(urlString: linkUrlString, title: title))
            }
        } catch {
            owsFailDebug("Could not parse link data: \(error).")
            return Promise(error: error)
        }
    }

    // Example:
    //
    //    <meta property="og:title" content="Randomness is Random - Numberphile">
    //    <meta property="og:image" content="https://i.ytimg.com/vi/tP-Ipsat90c/maxresdefault.jpg">
    class func parse(linkData: Data) throws -> OWSLinkPreviewContents {
        guard let linkText = String(bytes: linkData, encoding: .utf8) else {
            owsFailDebug("Could not parse link text.")
            throw LinkPreviewError.invalidInput
        }

        var title: String?
        if let rawTitle = NSRegularExpression.parseFirstMatch(pattern: "<meta\\s+property\\s*=\\s*\"og:title\"\\s+[^>]*content\\s*=\\s*\"(.*?)\"\\s*[^>]*/?>",
                                                              text: linkText,
                                                              options: .dotMatchesLineSeparators) {
            if let decodedTitle = decodeHTMLEntities(inString: rawTitle) {
                let normalizedTitle = OWSLinkPreview.normalizeTitle(title: decodedTitle)
                if normalizedTitle.count > 0 {
                    title = normalizedTitle
                }
            }
        }

        Logger.verbose("title: \(String(describing: title))")

        guard let rawImageUrlString = NSRegularExpression.parseFirstMatch(pattern: "<meta\\s+property\\s*=\\s*\"og:image\"\\s+[^>]*content\\s*=\\s*\"(.*?)\"[^>]*/?>", text: linkText) else {
            return OWSLinkPreviewContents(title: title)
        }
        guard let imageUrlString = decodeHTMLEntities(inString: rawImageUrlString)?.ows_stripped() else {
            return OWSLinkPreviewContents(title: title)
        }

        return OWSLinkPreviewContents(title: title, imageUrl: imageUrlString)
    }

    class func fileExtension(forImageUrl urlString: String) -> String? {
        guard let imageUrl = URL(string: urlString) else {
            Logger.error("Could not parse image URL.")
            return nil
        }
        let imageFilename = imageUrl.lastPathComponent
        let imageFileExtension = (imageFilename as NSString).pathExtension.lowercased()
        guard imageFileExtension.count > 0 else {
            return nil
        }
        return imageFileExtension
    }
    
    class func fileExtension(forMimeType mimeType: String) -> String? {
        switch mimeType {
        case OWSMimeTypeImageGif: return "gif"
        case OWSMimeTypeImagePng: return "png"
        case OWSMimeTypeImageJpeg: return "jpg"
        default: return nil
        }
    }

    class func mimetype(forImageFileExtension imageFileExtension: String) -> String? {
        guard imageFileExtension.count > 0 else {
            return nil
        }
        guard let imageMimeType = MIMETypeUtil.mimeType(forFileExtension: imageFileExtension) else {
            Logger.error("Image URL has unknown content type: \(imageFileExtension).")
            return nil
        }
        let kValidMimeTypes = [
            OWSMimeTypeImagePng,
            OWSMimeTypeImageJpeg,
            OWSMimeTypeImageGif,
        ]
        guard kValidMimeTypes.contains(imageMimeType) else {
            Logger.error("Image URL has invalid content type: \(imageMimeType).")
            return nil
        }
        return imageMimeType
    }

    private class func decodeHTMLEntities(inString value: String) -> String? {
        guard let data = value.data(using: .utf8) else {
            return nil
        }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            NSAttributedString.DocumentReadingOptionKey.documentType: NSAttributedString.DocumentType.html,
            NSAttributedString.DocumentReadingOptionKey.characterEncoding: String.Encoding.utf8.rawValue
        ]

        guard let attributedString = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }

        return attributedString.string
    }
}
