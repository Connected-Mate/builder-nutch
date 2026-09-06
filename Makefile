.PHONY: build test run
build:
	./Scripts/build-accounts.sh build
test:
	./Scripts/build-accounts.sh test
run: build
	open "build/AccountsDerivedData/Build/Products/Release/Builder Nutch.app"
