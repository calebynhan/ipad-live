APP := build/iPad Live.app

.PHONY: app run install test sender clean

# Build build/iPad Live.app
app:
	./scripts/build-app.sh

# Build and open it
run: app
	open "$(APP)"

# Build and copy it into /Applications
install: app
	rm -rf "/Applications/iPad Live.app"
	ditto "$(APP)" "/Applications/iPad Live.app"
	@echo "Installed: /Applications/iPad Live.app"

# Unit tests for the layout math (needs full Xcode, not just the Command Line Tools)
test:
	swift test

# Generate the iPad app's Xcode project and open it (needs Xcode, and XcodeGen: brew install xcodegen)
sender:
	@command -v xcodegen >/dev/null 2>&1 || { echo "XcodeGen isn't installed. Run: brew install xcodegen"; exit 1; }
	cd iPadSender && xcodegen generate
	open iPadSender/iPadLiveSender.xcodeproj

clean:
	rm -rf .build build
