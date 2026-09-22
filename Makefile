.PHONY: setup build test e2e clean

setup: build          ## first-time setup: build helper + server bundle

build:
	cd ax_helpers/macos && swift build -c release
	cd server && bun install && bun run build

test:                 ## no UI touched (browser tests use a headless temp-profile Chrome)
	cd ax_helpers/macos && swift test
	cd server && bun run typecheck && bun test

e2e:                  ## drives TextEdit for real
	cd ax_helpers/macos && $(MAKE) e2e

clean:
	rm -rf ax_helpers/macos/.build server/dist server/node_modules
