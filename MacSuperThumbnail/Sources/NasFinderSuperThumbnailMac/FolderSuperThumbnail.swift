import AppKit
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A folder inside the selected root that is eligible for a folder Super
/// Thumbnail. `depth` orders processing bottom-up so a parent sheet can reuse
/// the already generated sheets of its child folders.
struct FolderEntry: Sendable {
    let url: URL
    let depth: Int
}

enum FolderProcessingState: Sendable {
    case generated
    case emptyIndexed
}

struct FolderProcessingResult: Sendable {
    let state: FolderProcessingState
    let thumbnailBytes: Int64
    let didBlur: Bool
    let usedChildFolderSheetCount: Int
}

/// One tile of the 3x3 contact sheet, in deterministic browser order.
struct FolderSheetChild: Equatable, Sendable {
    let name: String
    let isDirectory: Bool
}

/// Deterministic selection for the 3x3 contact sheet: visible children only,
/// folders first, then localized standard name order — the same default
/// ordering the NasFinder browser uses. At most 9 tiles.
enum FolderContactSheetPlanner {
    static let maximumTileCount = 9

    static func plan(children: [FolderSheetChild]) -> [FolderSheetChild] {
        let visible = children.filter { !$0.name.hasPrefix(".") }
        let ordered = visible.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let name = lhs.name.localizedStandardCompare(rhs.name)
            return name == .orderedAscending
        }
        return Array(ordered.prefix(maximumTileCount))
    }
}

/// Local-only skin-tone pixel heuristic. Thresholds are byte-identical to the
/// iOS SkinToneBlurPolicy: a completed sheet downsampled to 12x12 whose
/// skin-tone pixel share reaches 0.42 is blurred as a whole. No image ever
/// leaves this machine and no ML model is involved.
enum SheetSkinTonePolicy {
    static let requiredFraction = 0.42
    static let sampleSide = 12
    /// The 384 px sheet is displayed at roughly 192 pt on a 2x screen, so a
    /// blur visually equivalent to 2 points is 4 pixels of Gaussian radius.
    static let blurRadiusPixels = 4.0

    static func shouldBlur(skinToneCount: Int, sampleCount: Int) -> Bool {
        guard sampleCount > 0 else { return false }
        return Double(skinToneCount) / Double(sampleCount) >= requiredFraction
    }

    static func isSkinTone(red: UInt8, green: UInt8, blue: UInt8) -> Bool {
        let r = Int(red)
        let g = Int(green)
        let b = Int(blue)
        let maximum = max(r, g, b)
        let minimum = min(r, g, b)
        return r > 70
            && g > 35
            && b > 20
            && r > g
            && r > b
            && maximum - minimum > 24
            && abs(r - g) > 8
    }

    static func isSkinToneDominant(_ image: CGImage) -> Bool {
        let width = sampleSide
        let height = sampleSide
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var skinToneCount = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            if isSkinTone(
                red: pixels[offset],
                green: pixels[offset + 1],
                blue: pixels[offset + 2]
            ) {
                skinToneCount += 1
            }
        }
        return shouldBlur(skinToneCount: skinToneCount, sampleCount: width * height)
    }
}

extension VaultProcessor {
    private static var sheetPixelSize: Int { maxPixelSize }
    private static var tilePixelSize: Int { maxPixelSize / 3 }

    /// Every directory strictly inside the selected root, deepest first, so
    /// parents are composed after their children. The root itself is excluded
    /// because its record would live outside the selected root. Vault
    /// directories, hidden entries and symlinks are never visited.
    static func discoverFolders(in root: URL) throws -> [FolderEntry] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isHiddenKey,
            .isSymbolicLinkKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        let rootComponentCount = root.standardizedFileURL.pathComponents.count
        var folders: [FolderEntry] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isDirectory == true else { continue }
            if url.lastPathComponent == NasFinderVaultCompatibility.directoryName {
                enumerator.skipDescendants()
                continue
            }
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isHidden != true else {
                enumerator.skipDescendants()
                continue
            }
            let depth = url.standardizedFileURL.pathComponents.count - rootComponentCount
            folders.append(FolderEntry(url: url, depth: depth))
        }
        return folders.sorted {
            if $0.depth != $1.depth { return $0.depth > $1.depth }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    /// Builds or refreshes the folder Super Thumbnail for one folder. Folder
    /// sheets are always regenerated because their content follows the child
    /// listing; the write itself stays atomic and claim-coordinated. Throws
    /// for unreadable folders and on cancellation so those folders are never
    /// recorded as successful and remain retryable.
    static func processFolder(
        _ folder: FolderEntry,
        workerID: String
    ) throws -> FolderProcessingResult {
        try Task.checkCancellation()
        let children = try visibleChildren(of: folder.url)
        let parentVault = folder.url.deletingLastPathComponent()
            .appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
        try fileManager.createDirectory(at: parentVault, withIntermediateDirectories: true)

        let folderName = folder.url.lastPathComponent
        let sheetURL = parentVault.appendingPathComponent(
            NasFinderVaultCompatibility.folderThumbnailFilename(folderName: folderName)
        )
        let markerURL = parentVault.appendingPathComponent(
            NasFinderVaultCompatibility.folderEmptyMarkerFilename(folderName: folderName)
        )

        if children.isEmpty {
            try Task.checkCancellation()
            let marker = try JSONEncoder().encode(
                FolderEmptyMarker(engine: NasFinderVaultCompatibility.engineVersion)
            )
            try marker.write(to: markerURL, options: .atomic)
            try? fileManager.removeItem(at: sheetURL)
            return FolderProcessingResult(
                state: .emptyIndexed,
                thumbnailBytes: 0,
                didBlur: false,
                usedChildFolderSheetCount: 0
            )
        }

        let claimName = ".claim-" + sheetURL.deletingPathExtension().lastPathComponent
        let claim = parentVault.appendingPathComponent(claimName, isDirectory: true)
        try acquireClaim(at: claim, workerID: workerID)
        defer { try? fileManager.removeItem(at: claim) }

        var usedChildFolderSheets = 0
        let tiles = FolderContactSheetPlanner.plan(children: children).map { child in
            tileImage(
                for: child,
                in: folder.url,
                usedChildFolderSheets: &usedChildFolderSheets
            )
        }
        try Task.checkCancellation()
        var sheet = try composeSheet(tiles: tiles)
        let didBlur = SheetSkinTonePolicy.isSkinToneDominant(sheet)
        if didBlur {
            sheet = try blurred(sheet, radius: SheetSkinTonePolicy.blurRadiusPixels)
        }
        let data = try jpegData(from: sheet, quality: 0.82)
        try Task.checkCancellation()

        let temporary = parentVault.appendingPathComponent(".upload-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        do {
            if fileManager.fileExists(atPath: sheetURL.path) {
                _ = try fileManager.replaceItemAt(sheetURL, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: sheetURL)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        try? fileManager.removeItem(at: markerURL)
        return FolderProcessingResult(
            state: .generated,
            thumbnailBytes: Int64(data.count),
            didBlur: didBlur,
            usedChildFolderSheetCount: usedChildFolderSheets
        )
    }

    /// The already-generated vault artwork a sheet tile reuses, if any.
    /// A child folder resolves to its own folder sheet inside this folder's
    /// vault; a media file resolves to its file Super Thumbnail. Both come
    /// from earlier phases of the same run or previous runs, so composing a
    /// sheet never triggers recursive generation.
    static func tileArtworkURL(for child: FolderSheetChild, in folder: URL) -> URL? {
        let vault = folder.appendingPathComponent(
            NasFinderVaultCompatibility.directoryName,
            isDirectory: true
        )
        if child.isDirectory {
            let sheet = vault.appendingPathComponent(
                NasFinderVaultCompatibility.folderThumbnailFilename(folderName: child.name)
            )
            return fileManager.fileExists(atPath: sheet.path) ? sheet : nil
        }
        let childURL = folder.appendingPathComponent(child.name, isDirectory: false)
        guard SupportedMedia.kind(for: childURL) != nil,
              let filename = try? NasFinderVaultCompatibility.thumbnailFilename(for: childURL)
        else { return nil }
        let thumbnail = vault.appendingPathComponent(filename)
        return fileManager.fileExists(atPath: thumbnail.path) ? thumbnail : nil
    }

    private static func visibleChildren(of folder: URL) throws -> [FolderSheetChild] {
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isHiddenKey,
            .isSymbolicLinkKey,
        ]
        let contents = try fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        return contents.compactMap { url in
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isHidden != true,
                  values?.isSymbolicLink != true,
                  url.lastPathComponent != NasFinderVaultCompatibility.directoryName,
                  !url.lastPathComponent.hasPrefix(".")
            else { return nil }
            return FolderSheetChild(
                name: url.lastPathComponent,
                isDirectory: values?.isDirectory == true
            )
        }
    }

    private static func tileImage(
        for child: FolderSheetChild,
        in folder: URL,
        usedChildFolderSheets: inout Int
    ) -> CGImage? {
        guard let artworkURL = tileArtworkURL(for: child, in: folder) else {
            return placeholderTile(isDirectory: child.isDirectory)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: tilePixelSize,
        ]
        guard let source = CGImageSourceCreateWithURL(artworkURL as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            return placeholderTile(isDirectory: child.isDirectory)
        }
        if child.isDirectory { usedChildFolderSheets += 1 }
        return image
    }

    private static func placeholderTile(isDirectory: Bool) -> CGImage? {
        let side = tilePixelSize
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let background = isDirectory
            ? CGColor(red: 0.88, green: 0.93, blue: 0.99, alpha: 1)
            : CGColor(red: 0.94, green: 0.94, blue: 0.95, alpha: 1)
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))

        let symbolName = isDirectory ? "folder.fill" : "doc.fill"
        let tint = isDirectory
            ? NSColor(calibratedRed: 0.28, green: 0.56, blue: 0.92, alpha: 1)
            : NSColor(calibratedWhite: 0.62, alpha: 1)
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: CGFloat(side) * 0.38, weight: .semibold)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
            ) {
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let symbolSize = symbol.size
            let origin = CGPoint(
                x: (CGFloat(side) - symbolSize.width) / 2,
                y: (CGFloat(side) - symbolSize.height) / 2
            )
            symbol.draw(in: CGRect(origin: origin, size: symbolSize))
            NSGraphicsContext.current = previous
        }
        return context.makeImage()
    }

    private static func composeSheet(tiles: [CGImage?]) throws -> CGImage {
        let side = sheetPixelSize
        let tileSide = tilePixelSize
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw VaultProcessorError.cannotEncode }
        context.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.98, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .medium

        for (index, tile) in tiles.enumerated() where index < 9 {
            guard let tile else { continue }
            let column = index % 3
            let row = index / 3
            // Core Graphics origin is bottom-left; the first child appears in
            // the visual top-left cell.
            let cell = CGRect(
                x: CGFloat(column * tileSide),
                y: CGFloat(side - (row + 1) * tileSide),
                width: CGFloat(tileSide),
                height: CGFloat(tileSide)
            )
            context.saveGState()
            context.clip(to: cell)
            let scale = max(
                cell.width / CGFloat(tile.width),
                cell.height / CGFloat(tile.height)
            )
            let drawSize = CGSize(
                width: CGFloat(tile.width) * scale,
                height: CGFloat(tile.height) * scale
            )
            let drawOrigin = CGPoint(
                x: cell.midX - drawSize.width / 2,
                y: cell.midY - drawSize.height / 2
            )
            context.draw(tile, in: CGRect(origin: drawOrigin, size: drawSize))
            context.restoreGState()
        }
        guard let image = context.makeImage() else {
            throw VaultProcessorError.cannotEncode
        }
        return image
    }

    private static func blurred(_ image: CGImage, radius: Double) throws -> CGImage {
        let ciImage = CIImage(cgImage: image)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: radius)
            .cropped(to: CIImage(cgImage: image).extent)
        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        guard let output = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            throw VaultProcessorError.cannotEncode
        }
        return output
    }
}

private struct FolderEmptyMarker: Codable {
    let engine: Int
    var state = "empty"
    var indexedAt = Date()
}
