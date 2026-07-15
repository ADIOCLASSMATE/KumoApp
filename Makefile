SHELL := /bin/bash

SWIFT := swift
XCODEBUILD := xcodebuild
XCODEGEN := xcodegen
PRODUCT_APP := KumoApp
PRODUCT_CLI := kumo
APP_BUNDLE_ID := io.kumo.KumoApp
SCHEME_APP := KumoApp
SCHEME_PACKAGE := Kumo-Package
PROJECT := Kumo.xcodeproj
DERIVED_DATA := build
APP_PATH_DEBUG := $(DERIVED_DATA)/Build/Products/Debug/Kumo.app
APP_PATH_RELEASE := $(DERIVED_DATA)/Build/Products/Release/Kumo.app
SERVICE_PATH_DEBUG := $(DERIVED_DATA)/Build/Products/Debug/KumoService
SERVICE_PATH_RELEASE := $(DERIVED_DATA)/Build/Products/Release/KumoService
CLI_PATH_DEBUG := $(DERIVED_DATA)/Build/Products/Debug/kumo
CLI_PATH_RELEASE := $(DERIVED_DATA)/Build/Products/Release/kumo
RELEASE_OUTPUT := $(DERIVED_DATA)/release
DESTINATION ?= platform=macOS
BUILD_NUMBER ?= 1
SUBSTORE_RUNTIME_SCRIPT := Scripts/prepare_substore_runtime.sh
DEVELOPMENT_TEAM ?=
CODE_SIGN_IDENTITY ?=
NOTARY_KEY_PATH ?=
NOTARY_KEY_ID ?=
NOTARY_ISSUER_ID ?=

# Kumo supports Apple Silicon only.
ARCH ?= arm64
XCODE_ARCH := arm64

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show available commands.
	@awk 'BEGIN {FS = ":.*##"; printf "Kumo development commands:\n\n"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-18s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: generate
generate: ## Regenerate the Xcode project from project.yml using XcodeGen.
	$(XCODEGEN) generate

.PHONY: require-apple-silicon
require-apple-silicon:
	@test "$(ARCH)" = "arm64" || { echo "Kumo supports Apple Silicon only; ARCH must be arm64."; exit 1; }

.PHONY: prepare-substore-runtime
prepare-substore-runtime: require-apple-silicon ## Download the generated Sub-Store Node runtime into local resources.
	SUBSTORE_NODE_ARCH="$(XCODE_ARCH)" bash $(SUBSTORE_RUNTIME_SCRIPT)

.PHONY: app
app: generate ## Build the Kumo .app bundle in Debug to build/Build/Products/Debug.
	$(MAKE) prepare-substore-runtime
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME_APP) -configuration Debug -derivedDataPath $(DERIVED_DATA) build
	@if [ -x "$(SERVICE_PATH_DEBUG)" ]; then \
		mkdir -p "$(APP_PATH_DEBUG)/Contents/MacOS"; \
		cp "$(SERVICE_PATH_DEBUG)" "$(APP_PATH_DEBUG)/Contents/MacOS/KumoService"; \
		chmod 755 "$(APP_PATH_DEBUG)/Contents/MacOS/KumoService"; \
	fi
	@if [ -x "$(CLI_PATH_DEBUG)" ]; then \
		mkdir -p "$(APP_PATH_DEBUG)/Contents/Helpers"; \
		cp "$(CLI_PATH_DEBUG)" "$(APP_PATH_DEBUG)/Contents/Helpers/kumo"; \
		chmod 755 "$(APP_PATH_DEBUG)/Contents/Helpers/kumo"; \
	fi

.PHONY: require-release-signing
require-release-signing:
	@test -n "$(DEVELOPMENT_TEAM)" || { echo "Set DEVELOPMENT_TEAM to the Apple signing Team ID."; exit 1; }
	@test -n "$(CODE_SIGN_IDENTITY)" || { echo "Set CODE_SIGN_IDENTITY to a Developer ID Application identity."; exit 1; }
	@/usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -F "$(CODE_SIGN_IDENTITY)" | /usr/bin/grep -F "Developer ID Application:" | /usr/bin/grep -F "($(DEVELOPMENT_TEAM))" >/dev/null || { echo "CODE_SIGN_IDENTITY must identify an installed Developer ID Application certificate for Team $(DEVELOPMENT_TEAM)."; exit 1; }

.PHONY: require-release-notarization
require-release-notarization:
	@test -f "$(NOTARY_KEY_PATH)" || { echo "Set NOTARY_KEY_PATH to an App Store Connect API .p8 key."; exit 1; }
	@test -n "$(NOTARY_KEY_ID)" || { echo "Set NOTARY_KEY_ID for notarization."; exit 1; }
	@test -n "$(NOTARY_ISSUER_ID)" || { echo "Set NOTARY_ISSUER_ID for notarization."; exit 1; }

.PHONY: app-release
app-release: require-apple-silicon require-release-signing generate ## Build the signed Kumo .app bundle in Release to build/Build/Products/Release.
	SUBSTORE_FORCE_REFRESH=1 $(MAKE) prepare-substore-runtime
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME_APP) -configuration Release -derivedDataPath $(DERIVED_DATA) build ARCHS=$(XCODE_ARCH) ONLY_ACTIVE_ARCH=NO DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)" CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE=Manual $(if $(VERSION),MARKETING_VERSION="$(VERSION)" CURRENT_PROJECT_VERSION="$(BUILD_NUMBER)",)
	@if [ -x "$(SERVICE_PATH_RELEASE)" ]; then \
		mkdir -p "$(APP_PATH_RELEASE)/Contents/MacOS"; \
		cp "$(SERVICE_PATH_RELEASE)" "$(APP_PATH_RELEASE)/Contents/MacOS/KumoService"; \
		chmod 755 "$(APP_PATH_RELEASE)/Contents/MacOS/KumoService"; \
	fi
	@if [ -x "$(CLI_PATH_RELEASE)" ]; then \
		mkdir -p "$(APP_PATH_RELEASE)/Contents/Helpers"; \
		cp "$(CLI_PATH_RELEASE)" "$(APP_PATH_RELEASE)/Contents/Helpers/kumo"; \
		chmod 755 "$(APP_PATH_RELEASE)/Contents/Helpers/kumo"; \
	fi
	@for binary in \
		"$(APP_PATH_RELEASE)/Contents/MacOS/Kumo" \
		"$(APP_PATH_RELEASE)/Contents/MacOS/KumoService" \
		"$(APP_PATH_RELEASE)/Contents/Helpers/kumo" \
		"$(APP_PATH_RELEASE)/Contents/Resources/Kumo_KumoCoreKit.bundle/Contents/Resources/SubStore/node/bin/node"; do \
		test -x "$$binary" || { echo "Required release executable is missing: $$binary"; exit 1; }; \
		BINARY_ARCHS="$$(/usr/bin/lipo -archs "$$binary")" || exit 1; \
		test "$$BINARY_ARCHS" = "arm64" || { echo "Release executable is not arm64-only: $$binary ($$BINARY_ARCHS)"; exit 1; }; \
	done
	@/usr/bin/codesign --verify --strict --deep --all-architectures "$(APP_PATH_RELEASE)"
	@for signed_item in "$(APP_PATH_RELEASE)" "$(APP_PATH_RELEASE)/Contents/MacOS/KumoService" "$(APP_PATH_RELEASE)/Contents/Helpers/kumo"; do \
		SIGNING_INFO="$$(/usr/bin/codesign -dv --verbose=4 "$$signed_item" 2>&1)" || exit 1; \
		TEAM="$$(printf '%s\n' "$$SIGNING_INFO" | /usr/bin/awk -F= '/^TeamIdentifier=/{print $$2}')"; \
		AUTHORITY="$$(printf '%s\n' "$$SIGNING_INFO" | /usr/bin/awk -F= '/^Authority=Developer ID Application:/{print $$2; exit}')"; \
		RUNTIME="$$(printf '%s\n' "$$SIGNING_INFO" | /usr/bin/awk '/^CodeDirectory .*flags=.*\(.*runtime.*\)/{print "runtime"; exit}')"; \
		test "$$TEAM" = "$(DEVELOPMENT_TEAM)" && test -n "$$AUTHORITY" && test "$$RUNTIME" = "runtime" || { echo "$$signed_item must use hardened-runtime Developer ID Application signing for Team $(DEVELOPMENT_TEAM)."; exit 1; }; \
	done

.PHONY: require-release-version
require-release-version:
	@test -n "$(VERSION)" || { echo "Set VERSION, for example: make release-dmg VERSION=0.0.1"; exit 1; }
	@[[ "$(VERSION)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$$ ]] || { echo "VERSION must use numeric x.y.z format."; exit 1; }

.PHONY: release-dmg
release-dmg: require-apple-silicon require-release-version require-release-signing require-release-notarization ## Build release app, notarized DMG, and latest.yml. Requires VERSION=0.0.1.
	$(MAKE) app-release VERSION="$(VERSION)" BUILD_NUMBER="$(BUILD_NUMBER)" ARCH="$(ARCH)"
	VERSION="$(VERSION)" CHANNEL="$(CHANNEL)" RELEASE_TAG="$(RELEASE_TAG)" OUTPUT_DIR="$(RELEASE_OUTPUT)" APP_PATH="$(APP_PATH_RELEASE)" ARCH_NAME="arm64" DEVELOPMENT_TEAM="$(DEVELOPMENT_TEAM)" CODE_SIGN_IDENTITY="$(CODE_SIGN_IDENTITY)" NOTARY_KEY_PATH="$(NOTARY_KEY_PATH)" NOTARY_KEY_ID="$(NOTARY_KEY_ID)" NOTARY_ISSUER_ID="$(NOTARY_ISSUER_ID)" bash Scripts/make_release_artifacts.sh

.PHONY: release-artifacts
release-artifacts: release-dmg ## Alias for release-dmg.

.PHONY: release-manifest
release-manifest: release-dmg ## Alias for release-dmg; latest.yml is emitted beside the DMG.

.PHONY: quit-app
quit-app: ## Quit a running Kumo app before replacing the debug bundle.
	@osascript -e 'tell application id "$(APP_BUNDLE_ID)" to quit' >/dev/null 2>&1 || true
	@for attempt in 1 2 3 4 5 6 7 8 9 10; do \
		if pgrep -x "Kumo" >/dev/null; then \
			sleep 0.2; \
		else \
			break; \
		fi; \
	done
	@if pgrep -x "Kumo" >/dev/null; then \
		echo "Kumo is still running; sending SIGTERM before rebuilding."; \
		pkill -TERM -x "Kumo"; \
	fi

.PHONY: clean-debug-app
clean-debug-app: ## Remove the debug app bundle before rebuilding it.
	rm -rf "$(APP_PATH_DEBUG)"

.PHONY: dev
dev: ## Quit any running Kumo, build, and open the debug .app bundle.
	$(MAKE) quit-app
	$(MAKE) clean-debug-app
	$(MAKE) app
	open -n "$(APP_PATH_DEBUG)"

.PHONY: dev-cli
dev-cli: ## Run the SwiftUI macOS app via swift run (no .app bundle).
	$(MAKE) prepare-substore-runtime
	$(SWIFT) run $(PRODUCT_APP)

.PHONY: check
check: build test cli-status ## Build with Xcode, test, and verify the CLI status output.

.PHONY: build
build: app ## Build the Kumo .app bundle (alias for `make app`).

.PHONY: xcode-list
xcode-list: generate ## List Xcode schemes.
	$(XCODEBUILD) -project $(PROJECT) -list

.PHONY: xcode-build
xcode-build: app ## Build the KumoApp scheme via xcodebuild.

.PHONY: xcode-test
xcode-test: ## Run package tests via xcodebuild.
	$(MAKE) prepare-substore-runtime
	$(XCODEBUILD) -scheme $(SCHEME_PACKAGE) -destination '$(DESTINATION)' test

.PHONY: swift-build
swift-build: ## Build all Swift package products in debug mode.
	$(MAKE) prepare-substore-runtime
	$(SWIFT) build

.PHONY: build-release
build-release: ## Build all Swift package products in release mode.
	$(MAKE) prepare-substore-runtime
	$(SWIFT) build -c release

.PHONY: test
test: xcode-test ## Run unit tests with Xcode CLI.

.PHONY: swift-test
swift-test: ## Run unit tests with SwiftPM.
	$(MAKE) prepare-substore-runtime
	$(SWIFT) test

.PHONY: run-cli
run-cli: ## Run the Kumo CLI. Override ARGS, for example: make run-cli ARGS="status --json".
	$(MAKE) prepare-substore-runtime
	$(SWIFT) run $(PRODUCT_CLI) $(ARGS)

.PHONY: cli-status
cli-status: ## Print CLI status as JSON.
	$(SWIFT) run $(PRODUCT_CLI) status --json

.PHONY: cli-sysproxy-dry-run
cli-sysproxy-dry-run: ## Show system proxy commands without applying them.
	$(SWIFT) run $(PRODUCT_CLI) sysproxy on --dry-run --json

.PHONY: docs
docs: ## List technical documentation files.
	@printf "Technical docs:\n"
	@find docs -name '*.md' | sort

.PHONY: clean
clean: ## Remove Swift build artifacts.
	$(SWIFT) package clean
	rm -rf $(DERIVED_DATA)

.PHONY: xcode-clean
xcode-clean: ## Clean the KumoApp scheme via xcodebuild.
	$(XCODEBUILD) -project $(PROJECT) -scheme $(SCHEME_APP) -configuration Debug clean

.PHONY: reset-local-state
reset-local-state: ## Remove local Kumo application support data.
	rm -rf "$$HOME/Library/Application Support/Kumo"
