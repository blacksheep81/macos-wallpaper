import AppKit
import SQLite

public enum Wallpaper {
	public enum Screen {
		case all
		case main
		case index(Int)
		case nsScreens([NSScreen])

		fileprivate var nsScreens: [NSScreen] {
			switch self {
			case .all:
				return NSScreen.screens
			case .main:
				guard let mainScreen = NSScreen.main else {
					return []
				}

				return [mainScreen]
			case .index(let index):
				guard let screen = NSScreen.screens[safe: index] else {
					return []
				}

				return [screen]
			case .nsScreens(let nsScreens):
				return nsScreens
			}
		}
	}

	public enum Scale: String, CaseIterable {
		case auto
		case fill
		case fit
		case stretch
		case center
	}

	/**
	Works around macOS bug where it sometimes returns a directory instead of an image.

	https://openradar.appspot.com/radar?id=4959084113559552

	Note: This workaround is only needed on macOS versions prior to macOS 26. On macOS 26+, the database schema may have changed or may not exist, and NSWorkspace.shared.desktopImageURL appears to return proper file paths.
	*/
	private static func imageURL(for value: String, in directoryURL: URL) -> URL {
		if
			let fileURL = URL(string: value),
			fileURL.isFileURL
		{
			return fileURL
		}

		let expanded = (value as NSString).expandingTildeInPath
		if (expanded as NSString).isAbsolutePath {
			return URL(fileURLWithPath: expanded, isDirectory: false)
		}

		return directoryURL.appendingPathComponent(value, isDirectory: false)
	}

	private static func scalarString(
		_ query: String,
		binding: String? = nil,
		database: Connection
	) -> String? {
		do {
			let value: Binding?
			if let binding {
				value = try database.scalar(query, binding)
			} else {
				value = try database.scalar(query)
			}

			guard let image = value as? String, !image.isEmpty else {
				return nil
			}

			return image
		} catch {
			return nil
		}
	}

	/**
	Resolve the current image for a directory-backed wallpaper from `desktoppicture.db`.

	`NSWorkspace.desktopImageURL(for:)` is already screen-specific, but when the wallpaper is a rotating folder it returns that folder for every display. The Dock database stores the actual file per display:

	- `preferences.key = 16`: current image while auto-rotation is enabled
	- `preferences.key = 1`: static image path
	*/
	static func resolveDirectoryWallpaper(
		_ directoryURL: URL,
		displayUUID: String?,
		database: Connection
	) throws -> URL {
		// Prefer the display-specific row, then a global (display_id IS NULL) row.
		// Key 16 is the currently visible file in a rotating directory; key 1 is a static image.
		let preferenceOrder = """
			ORDER BY
				CASE preferences.key WHEN 16 THEN 0 ELSE 1 END,
				preferences.ROWID DESC
			LIMIT 1
			"""

		if let displayUUID {
			let displayQuery = """
				SELECT data.value
				FROM preferences
				JOIN data ON preferences.data_id = data.ROWID
				JOIN pictures ON preferences.picture_id = pictures.ROWID
				JOIN displays ON pictures.display_id = displays.ROWID
				WHERE preferences.key IN (16, 1)
					AND displays.display_uuid = ? COLLATE NOCASE
				\(preferenceOrder)
				"""

			if let image = scalarString(displayQuery, binding: displayUUID, database: database) {
				return imageURL(for: image, in: directoryURL)
			}
		}

		let globalQuery = """
			SELECT data.value
			FROM preferences
			JOIN data ON preferences.data_id = data.ROWID
			JOIN pictures ON preferences.picture_id = pictures.ROWID
			WHERE preferences.key IN (16, 1)
				AND pictures.display_id IS NULL
			\(preferenceOrder)
			"""

		if let image = scalarString(globalQuery, database: database) {
			return imageURL(for: image, in: directoryURL)
		}

		// Older / incomplete schemas have no display relationships; keep the previous global lookup.
		let legacyQuery = "SELECT value FROM data ORDER BY ROWID DESC LIMIT 1"
		guard let image = scalarString(legacyQuery, database: database) else {
			throw NSError(
				domain: "WallpaperError",
				code: 2,
				userInfo: [NSLocalizedDescriptionKey: "Could not resolve the current wallpaper from the desktop picture database."]
			)
		}

		return imageURL(for: image, in: directoryURL)
	}

	private static func getFromDirectory(_ url: URL, screen: NSScreen) throws -> URL {
		// On macOS 26+, skip the database workaround as it may not be available
		// and the underlying bug appears to be fixed
		if #available(macOS 26, *) {
			return url
		}

		let appSupportDirectory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
		let dbURL = appSupportDirectory.appendingPathComponent("Dock/desktoppicture.db", isDirectory: false)
		let db = try Connection(dbURL.path)

		return try resolveDirectoryWallpaper(url, displayUUID: screen.displayUUID, database: db)
	}

	/**
	Get the current wallpapers.
	*/
	public static func get(screen: Screen = .all) throws -> [URL] {
		screen.nsScreens.compactMap { nsScreen in
			guard let url = NSWorkspace.shared.desktopImageURL(for: nsScreen) else {
				return nil
			}

			if url.isDirectory {
				// Try to get specific image from directory, fall back to directory if it fails (e.g., in sandbox)
				return (try? getFromDirectory(url, screen: nsScreen)) ?? url
			}

			return url
		}
	}

	/**
	Validates that a file or directory exists and is accessible.
	*/
	private static func validateFile(_ url: URL) throws {
		var isDirectory: ObjCBool = false

		guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
			throw NSError(
				domain: "WallpaperError",
				code: 1,
				userInfo: [NSLocalizedDescriptionKey: "The file doesn't exist."]
			)
		}

		// For files, ensure they're actually accessible
		if !isDirectory.boolValue {
			guard (try? url.checkResourceIsReachable()) == true else {
				throw NSError(
					domain: "WallpaperError",
					code: 1,
					userInfo: [NSLocalizedDescriptionKey: "The file exists but is not accessible."]
				)
			}
		}
	}

	/**
	Works around a macOS bug where if you set a wallpaper to the same path as the existing wallpaper but with different content, it doesn't update.

	https://openradar.appspot.com/radar?id=6095446787227648
	*/
	private static func forceRefreshIfNeeded(_ image: URL, screen: Screen) throws {
		var shouldSleep = false
		let currentImages = try get(screen: screen)

		for (index, nsScreen) in screen.nsScreens.enumerated() {
			if image == currentImages[index] {
				shouldSleep = true
				try NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: ""), for: nsScreen, options: [:])
			}
		}

		if shouldSleep {
			// We need to sleep for a little bit, otherwise it doesn't take effect.
			// It works with 0.3, but not with 0.2, so we're using 0.4 just to be sure.
			sleep(for: 0.4)
		}
	}

	/**
	Set an image URL as wallpaper.
	*/
	public static func set(
		_ image: URL,
		screen: Screen = .all,
		scale: Scale = .auto,
		fillColor: NSColor? = nil
	) throws {
		// Validate that the file or directory exists and is accessible
		try validateFile(image)

		var options = [NSWorkspace.DesktopImageOptionKey: Any]()

		switch scale {
		case .auto:
			break
		case .fill:
			options[.imageScaling] = NSImageScaling.scaleProportionallyUpOrDown.rawValue
			options[.allowClipping] = true
		case .fit:
			options[.imageScaling] = NSImageScaling.scaleProportionallyUpOrDown.rawValue
			options[.allowClipping] = false
		case .stretch:
			options[.imageScaling] = NSImageScaling.scaleAxesIndependently.rawValue
			options[.allowClipping] = true
		case .center:
			options[.imageScaling] = NSImageScaling.scaleNone.rawValue
			options[.allowClipping] = false
		}

		options[.fillColor] = fillColor

		try forceRefreshIfNeeded(image, screen: screen)

		for nsScreen in screen.nsScreens {
			try NSWorkspace.shared.setDesktopImageURL(image, for: nsScreen, options: options)
		}
	}

	/**
	Set a solid color as wallpaper.
	*/
	public static func set(_ solidColor: NSColor, screen: Screen = .all) throws {
		let transparentImage = URL(fileURLWithPath: "/System/Library/PreferencePanes/DesktopScreenEffectsPref.prefPane/Contents/Resources/DesktopPictures.prefPane/Contents/Resources/Transparent.tiff")

		try set(transparentImage, screen: screen, scale: .fit, fillColor: solidColor)
	}

	/**
	Names of available screens.
	*/
	public static var screenNames: [String] {
		NSScreen.screens.map(\.name)
	}
}
