APP := build/iPad Live.app

.PHONY: app run install test clean

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

clean:
	rm -rf .build build
