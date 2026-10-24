# Local commands, mirroring CI plus the macOS-only checks CI skips to save Actions minutes.
SWIFT_SOURCES := main.swift ios/DeskBar ios/Shared ios/DeskBarWidget tests
IOS_SDK = $(shell xcrun --sdk iphoneos --show-sdk-path)

.PHONY: format lint complexity test typecheck check ci

format:
	xcrun swift-format format --in-place --recursive --configuration .swift-format $(SWIFT_SOURCES)

lint:
	xcrun swift-format lint --strict --recursive --configuration .swift-format $(SWIFT_SOURCES)
	swiftlint lint --strict --quiet

# Cyclomatic complexity 15, function length 60 lines, 5 parameters
complexity:
	lizard -l swift -C 15 -L 60 -a 5 -w $(SWIFT_SOURCES)

test:
	./tests/run-logic-tests.sh

typecheck:
	swiftc -typecheck main.swift
	xcrun swiftc -typecheck -sdk $(IOS_SDK) -target arm64-apple-ios17.0 ios/DeskBar/*.swift ios/Shared/*.swift
	xcrun swiftc -typecheck -sdk $(IOS_SDK) -target arm64-apple-ios17.0 ios/DeskBarWidget/*.swift ios/Shared/*.swift

check: lint complexity test typecheck
ci: check
