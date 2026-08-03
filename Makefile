EXE_PATH := learnvk
COMPILE := odin build . -out:$(EXE_PATH) -build-mode:exe

COMMON_FLAGS := -vet-cast -vet-semicolon -vet-shadowing -vet-style -vet-using-param -vet-using-stmt -thread-count:12 -warnings-as-errors
DEBUG_FLAGS := $(COMMON_FLAGS) -debug
RELEASE_FLAGS := $(COMMON_FLAGS) -o:speed -lto:thin -no-bounds-check -vet-unused-variables
# RELEASE_FLAGS := $(COMMON_FLAGS) -o:speed -disable-assert -lto:thin -no-bounds-check -source-code-locations:none

.PHONY: debug release t r rr

debug:
	@echo "debug compile..."
	$(COMPILE) $(DEBUG_FLAGS)

release:
	@echo "release compile..."
	$(COMPILE) $(RELEASE_FLAGS)

t:
	odin test . -all-packages

r: debug
	./$(EXE_PATH)

rr: release
	./$(EXE_PATH)
