NAME    := DHLFix
SDK     := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC      := xcrun -sdk iphoneos clang
CFLAGS  := -arch arm64 -miphoneos-version-min=15.0 -isysroot $(SDK) -fobjc-arc -O2 -Wall
LDFLAGS := -dynamiclib -framework Foundation -framework WebKit -install_name @rpath/$(NAME).dylib

build/$(NAME).dylib: src/$(NAME).m src/DHLFixTransform.c src/DHLFixTransform.h
	@mkdir -p build
	$(CC) $(CFLAGS) $(LDFLAGS) src/$(NAME).m src/DHLFixTransform.c -o $@
	ldid -S $@
	@echo "built $@"

clean:
	rm -rf build

.PHONY: clean
