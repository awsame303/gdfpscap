# fpsuncap -- uncap Geometry Dash's frame loop on macOS

VERSION  := 1.0.0
BUILD    := build
ARCHS    := -arch arm64 -arch x86_64
CFLAGS   := -O2 -Wall -Wextra -Wno-deprecated-declarations
FRAMEWORKS := -framework CoreVideo -framework CoreFoundation -framework OpenGL

.PHONY: all app pkg test install uninstall status clean

all: $(BUILD)/fpsuncap.dylib $(BUILD)/machsplice $(BUILD)/fpsuncap

$(BUILD):
	@mkdir -p $(BUILD)

# Universal so it works under both native arm64 and Rosetta.
$(BUILD)/fpsuncap.dylib: src/fpsuncap.c | $(BUILD)
	clang $(ARCHS) -dynamiclib $(CFLAGS) $(FRAMEWORKS) \
	  -install_name @rpath/fpsuncap.dylib -o $@ $<
	@codesign -f -s - $@
	@echo "built $@"

$(BUILD)/machsplice: tools/machsplice.c | $(BUILD)
	clang $(ARCHS) $(CFLAGS) -o $@ $<
	@codesign -f -s - $@

$(BUILD)/fpsuncap: tools/fpsuncap | $(BUILD)
	@cp tools/fpsuncap $@ && chmod +x $@

app: all
	@./app/build-app.sh $(BUILD) $(VERSION)

pkg: all
	@./app/build-pkg.sh $(BUILD) $(VERSION)

test: all
	@./tests/run-tests.sh

install: all
	@./tools/fpsuncap install

uninstall:
	@./tools/fpsuncap uninstall

status:
	@./tools/fpsuncap status

clean:
	rm -rf $(BUILD)
