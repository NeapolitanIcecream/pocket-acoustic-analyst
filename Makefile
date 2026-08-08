.PHONY: bootstrap build test test-core clean

bootstrap:
	xcodegen generate

build: bootstrap
	xcodebuild -project PocketAcousticAnalyst.xcodeproj -scheme PocketAcousticAnalyst -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build

test: bootstrap
	xcodebuild -project PocketAcousticAnalyst.xcodeproj -scheme PocketAcousticAnalyst -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test

test-core: bootstrap
	xcodebuild -project PocketAcousticAnalyst.xcodeproj -scheme PocketAcousticAnalyst -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO -only-testing:PocketAcousticAnalystTests test

clean:
	xcodebuild -project PocketAcousticAnalyst.xcodeproj -scheme PocketAcousticAnalyst -derivedDataPath DerivedData clean

