NAME    := DHLFix
SDK     := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC      := xcrun -sdk iphoneos clang
CFLAGS  := -arch arm64 -miphoneos-version-min=15.0 -isysroot $(SDK) -fobjc-arc -O2 -Wall -Ibuild
LDFLAGS := -dynamiclib -framework Foundation -framework WebKit -install_name @rpath/$(NAME).dylib
SRCS    := src/$(NAME).m src/DHLFixTransform.c

build/$(NAME).dylib: $(SRCS) src/DHLFixTransform.h build/DHLFixPage.h
	$(CC) $(CFLAGS) $(LDFLAGS) $(SRCS) -o $@
	ldid -S $@
	@echo "built $@"

# embed the page script as a C string
build/DHLFixPage.h: src/DHLFixPage.js
	@mkdir -p build
	node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");process.stdout.write("static const char kDHLFixPageJS[] = "+JSON.stringify(s)+";\n")' $< > $@

clean:
	rm -rf build

.PHONY: clean
