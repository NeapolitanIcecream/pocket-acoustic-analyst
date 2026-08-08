.PHONY: bootstrap build test test-core analyze lint clean

SIMULATOR_DESTINATION ?= platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6

bootstrap:
	xcodegen generate

build: bootstrap
	xcodebuild -project PocketAcousticAnalyst.xcodeproj -scheme PocketAcousticAnalyst -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build

test: bootstrap
	xcodebuild -project PocketAcousticAnalyst.xcodeproj -scheme PocketAcousticAnalyst -destination '$(SIMULATOR_DESTINATION)' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test

test-core: bootstrap
	xcodebuild -project PocketAcousticAnalyst.xcodeproj -scheme PocketAcousticAnalyst -destination '$(SIMULATOR_DESTINATION)' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO -only-testing:PocketAcousticAnalystTests test

analyze: bootstrap
	xcodebuild -project PocketAcousticAnalyst.xcodeproj -scheme PocketAcousticAnalyst -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO analyze

lint:
	xcrun swift-format lint --strict -r PocketAcousticAnalyst PocketAcousticAnalystTests PocketAcousticAnalystUITests

clean:
	xcodebuild -project PocketAcousticAnalyst.xcodeproj -scheme PocketAcousticAnalyst -derivedDataPath DerivedData clean
