NAME    := DHLFix
SDK     := $(shell xcrun --sdk iphoneos --show-sdk-path)
CC      := xcrun -sdk iphoneos clang
CFLAGS  := -arch arm64 -miphoneos-version-min=15.0 -isysroot $(SDK) -fobjc-arc -O2 -Wall -Ibuild
LDFLAGS := -dynamiclib -framework Foundation -framework WebKit -install_name @rpath/$(NAME).dylib
SRCS    := src/$(NAME).m src/DHLFixTransform.c

ifeq ($(DEBUG),1)
CFLAGS  += -DDHLFIX_DEBUG
endif

build/$(NAME).dylib: $(SRCS) src/DHLFixTransform.h build/DHLFixPage.h FORCE
	$(CC) $(CFLAGS) $(LDFLAGS) $(SRCS) -o $@
	ldid -S $@
	@echo "built $@$(if $(filter 1,$(DEBUG)), (debug logging))"

# embed the page script as a C string
build/DHLFixPage.h: src/DHLFixPage.js
	@mkdir -p build
	node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");process.stdout.write("static const char kDHLFixPageJS[] = "+JSON.stringify(s)+";\n")' $< > $@

# lowers tests/static-blocks.js on the Mac and checks that both versions behave the same
test: build/lower tools/node_modules
	@node --check src/DHLFixPage.js
	@build/lower tests/static-blocks.js build/static-blocks.lowered.js
	@node tools/no-static-blocks.mjs build/static-blocks.lowered.js
	@node tests/static-blocks.js > build/expected.txt
	@node build/static-blocks.lowered.js > build/actual.txt
	@diff build/expected.txt build/actual.txt && echo "test ok: $$(cat build/actual.txt)"

build/lower: tests/lower.c src/DHLFixTransform.c src/DHLFixTransform.h
	@mkdir -p build
	clang -O2 -Wall -o $@ tests/lower.c src/DHLFixTransform.c

tools/node_modules: tools/package.json
	cd tools && npm install --silent --no-fund --no-audit

clean:
	rm -rf build

FORCE:
.PHONY: clean test FORCE
