SOURCES := $(wildcard Sources/*.swift)
BUILD := build
MINIMUM := 13.0
SWIFTFLAGS := -O -swift-version 5 -parse-as-library

.PHONY: all clean

all: $(BUILD)/xixo-mac-reader

$(BUILD)/xixo-mac-reader-%: $(SOURCES)
	@mkdir -p $(BUILD)
	xcrun swiftc $(SWIFTFLAGS) -target $*-apple-macos$(MINIMUM) -o $@ $(SOURCES)

$(BUILD)/xixo-mac-reader: $(BUILD)/xixo-mac-reader-arm64 $(BUILD)/xixo-mac-reader-x86_64
	lipo -create -output $@ $^
	codesign --force --sign - $@

clean:
	rm -rf $(BUILD)
