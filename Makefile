.PHONY: bootstrap build test test-core test-device-core test-device-demo-ui test-device-audio test-device-ar check-device-config analyze lint clean

SIMULATOR_DESTINATION ?= platform=iOS Simulator,name=iPhone 16 Pro,OS=18.6
DEVICE_ID ?=
DEVELOPMENT_TEAM ?=

bootstrap:
	xcodegen generate

build: bootstrap
	xcodebuild -project PocketAcousticAnalyst.xcodeproj -scheme PocketAcousticAnalyst -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build

test: bootstrap
	xcodebuild -project PocketAcousticAnalyst.xcodeproj -scheme PocketAcousticAnalyst -destination '$(SIMULATOR_DESTINATION)' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO test

test-core: bootstrap
	xcodebuild -project PocketAcousticAnalyst.xcodeproj -scheme PocketAcousticAnalyst -destination '$(SIMULATOR_DESTINATION)' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO -only-testing:PocketAcousticAnalystTests test

check-device-config:
	@test -n '$(DEVICE_ID)' || { echo 'DEVICE_ID is required'; exit 1; }
	@test -n '$(DEVELOPMENT_TEAM)' || { echo 'DEVELOPMENT_TEAM is required'; exit 1; }

test-device-core: bootstrap check-device-config
	xcodebuild -project PocketAcousticAnalyst.xcodeproj -scheme PocketAcousticAnalyst -destination 'platform=iOS,id=$(DEVICE_ID)' -derivedDataPath DerivedData DEVELOPMENT_TEAM='$(DEVELOPMENT_TEAM)' CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates -only-testing:PocketAcousticAnalystTests test

test-device-demo-ui: bootstrap check-device-config
	xcodebuild -project PocketAcousticAnalyst.xcodeproj -scheme PocketAcousticAnalyst -destination 'platform=iOS,id=$(DEVICE_ID)' -derivedDataPath DerivedData DEVELOPMENT_TEAM='$(DEVELOPMENT_TEAM)' CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates -only-testing:PocketAcousticAnalystUITests/LaunchTests/testHomeStartsWithAProblemInsteadOfAnInstrument -only-testing:PocketAcousticAnalystUITests/LaunchTests/testDemoCompletesGuidedHumMeasurement -only-testing:PocketAcousticAnalystUITests/LaunchTests/testIntermittentDemoExplainsTheEvidenceAndOpensHistoryDetails -only-testing:PocketAcousticAnalystUITests/LaunchTests/testDemoCompletesMeasuredPointScanWithOriginClosure -only-testing:PocketAcousticAnalystUITests/LaunchTests/testDemoCompletesBeforeAfterValidation -only-testing:PocketAcousticAnalystUITests/LaunchTests/testDemoCompletesThreeRoundSourceInvestigation test

test-device-audio: bootstrap check-device-config
	xcodebuild -project PocketAcousticAnalyst.xcodeproj -scheme PocketAcousticAnalyst -destination 'platform=iOS,id=$(DEVICE_ID)' -derivedDataPath DerivedData DEVELOPMENT_TEAM='$(DEVELOPMENT_TEAM)' CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates -only-testing:PocketAcousticAnalystUITests/LaunchTests/testRealDeviceCompletesAmbientAudioCapture test

test-device-ar: bootstrap check-device-config
	xcodebuild -project PocketAcousticAnalyst.xcodeproj -scheme PocketAcousticAnalyst -destination 'platform=iOS,id=$(DEVICE_ID)' -derivedDataPath DerivedData DEVELOPMENT_TEAM='$(DEVELOPMENT_TEAM)' CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates -only-testing:PocketAcousticAnalystUITests/LaunchTests/testRealDeviceCapturesARTrackedOrigin test

analyze: bootstrap
	xcodebuild -project PocketAcousticAnalyst.xcodeproj -scheme PocketAcousticAnalyst -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO analyze

lint:
	xcrun swift-format lint --strict -r PocketAcousticAnalyst PocketAcousticAnalystTests PocketAcousticAnalystUITests

clean:
	xcodebuild -project PocketAcousticAnalyst.xcodeproj -scheme PocketAcousticAnalyst -derivedDataPath DerivedData clean
