import Foundation
import SQLite
import XCTest
@testable import Wallpaper

final class WallpaperTests: XCTestCase {
	private func makeDatabase() throws -> Connection {
		let database = try Connection(.inMemory)
		try database.run("CREATE TABLE pictures (space_id INTEGER, display_id INTEGER)")
		try database.run("CREATE TABLE preferences (key INTEGER, data_id INTEGER, picture_id INTEGER)")
		try database.run("CREATE TABLE displays (display_uuid)")
		try database.run("CREATE TABLE data (value)")
		return database
	}

	@discardableResult
	private func addDisplay(_ displayUUID: String, to database: Connection) throws -> Int64 {
		try database.run("INSERT INTO displays (display_uuid) VALUES (?)", displayUUID)
		return database.lastInsertRowid
	}

	private func addWallpaper(
		_ value: String,
		displayID: Int64?,
		key: Int = 1,
		to database: Connection
	) throws {
		try database.run("INSERT INTO data (value) VALUES (?)", value)
		let dataID = database.lastInsertRowid

		try database.run("INSERT INTO pictures (space_id, display_id) VALUES (NULL, ?)", displayID)
		let pictureID = database.lastInsertRowid

		try database.run(
			"INSERT INTO preferences (key, data_id, picture_id) VALUES (?, ?, ?)",
			key,
			dataID,
			pictureID
		)
	}

	func testResolvesWallpaperForEachDisplay() throws {
		let database = try makeDatabase()
		let firstDisplayID = try addDisplay("FIRST-DISPLAY", to: database)
		let secondDisplayID = try addDisplay("SECOND-DISPLAY", to: database)
		try addWallpaper("first.jpg", displayID: firstDisplayID, to: database)
		try addWallpaper("second.jpg", displayID: secondDisplayID, to: database)
		try addWallpaper("global.jpg", displayID: nil, to: database)
		let directoryURL = URL(fileURLWithPath: "/wallpapers", isDirectory: true)

		let firstWallpaper = try Wallpaper.resolveDirectoryWallpaper(
			directoryURL,
			displayUUID: "FIRST-DISPLAY",
			database: database
		)
		let secondWallpaper = try Wallpaper.resolveDirectoryWallpaper(
			directoryURL,
			displayUUID: "SECOND-DISPLAY",
			database: database
		)

		XCTAssertEqual(firstWallpaper.path, "/wallpapers/first.jpg")
		XCTAssertEqual(secondWallpaper.path, "/wallpapers/second.jpg")
	}

	func testPrefersRotatingCurrentImageOverStaticPath() throws {
		let database = try makeDatabase()
		let displayID = try addDisplay("DISPLAY", to: database)
		try addWallpaper("static.jpg", displayID: displayID, key: 1, to: database)
		try addWallpaper("rotated.jpg", displayID: displayID, key: 16, to: database)

		let wallpaper = try Wallpaper.resolveDirectoryWallpaper(
			URL(fileURLWithPath: "/wallpapers", isDirectory: true),
			displayUUID: "DISPLAY",
			database: database
		)

		XCTAssertEqual(wallpaper.path, "/wallpapers/rotated.jpg")
	}

	func testUsesMostRecentWallpaperForDisplay() throws {
		let database = try makeDatabase()
		let displayID = try addDisplay("DISPLAY", to: database)
		try addWallpaper("previous.jpg", displayID: displayID, to: database)
		try addWallpaper("current.jpg", displayID: displayID, to: database)

		let wallpaper = try Wallpaper.resolveDirectoryWallpaper(
			URL(fileURLWithPath: "/wallpapers", isDirectory: true),
			displayUUID: "DISPLAY",
			database: database
		)

		XCTAssertEqual(wallpaper.path, "/wallpapers/current.jpg")
	}

	func testMatchesDisplayUUIDCaseInsensitively() throws {
		let database = try makeDatabase()
		let displayID = try addDisplay("ABC-DEF", to: database)
		try addWallpaper("current.jpg", displayID: displayID, to: database)

		let wallpaper = try Wallpaper.resolveDirectoryWallpaper(
			URL(fileURLWithPath: "/wallpapers", isDirectory: true),
			displayUUID: "abc-def",
			database: database
		)

		XCTAssertEqual(wallpaper.path, "/wallpapers/current.jpg")
	}

	func testFallsBackToGlobalWallpaper() throws {
		let database = try makeDatabase()
		try addWallpaper("global.jpg", displayID: nil, to: database)

		let wallpaper = try Wallpaper.resolveDirectoryWallpaper(
			URL(fileURLWithPath: "/wallpapers", isDirectory: true),
			displayUUID: "UNKNOWN-DISPLAY",
			database: database
		)

		XCTAssertEqual(wallpaper.path, "/wallpapers/global.jpg")
	}

	func testPreservesAbsoluteWallpaperPath() throws {
		let database = try makeDatabase()
		let displayID = try addDisplay("DISPLAY", to: database)
		try addWallpaper("/other/wallpapers/current.jpg", displayID: displayID, to: database)

		let wallpaper = try Wallpaper.resolveDirectoryWallpaper(
			URL(fileURLWithPath: "/wallpapers", isDirectory: true),
			displayUUID: "DISPLAY",
			database: database
		)

		XCTAssertEqual(wallpaper.path, "/other/wallpapers/current.jpg")
	}

	func testPreservesFileURLWallpaperPath() throws {
		let database = try makeDatabase()
		let displayID = try addDisplay("DISPLAY", to: database)
		try addWallpaper("file:///other/wallpapers/current.jpg", displayID: displayID, to: database)

		let wallpaper = try Wallpaper.resolveDirectoryWallpaper(
			URL(fileURLWithPath: "/wallpapers", isDirectory: true),
			displayUUID: "DISPLAY",
			database: database
		)

		XCTAssertEqual(wallpaper.path, "/other/wallpapers/current.jpg")
	}

	func testSupportsLegacyDatabaseSchema() throws {
		let database = try Connection(.inMemory)
		try database.run("CREATE TABLE data (value)")
		try database.run("INSERT INTO data (value) VALUES ('previous.jpg')")
		try database.run("INSERT INTO data (value) VALUES ('current.jpg')")

		let wallpaper = try Wallpaper.resolveDirectoryWallpaper(
			URL(fileURLWithPath: "/wallpapers", isDirectory: true),
			displayUUID: "DISPLAY",
			database: database
		)

		XCTAssertEqual(wallpaper.path, "/wallpapers/current.jpg")
	}
}
