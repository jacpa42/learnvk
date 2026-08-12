MAIN_EXE_PATH := bin/learnvk
COMPILE_MAIN := odin build . -out:$(MAIN_EXE_PATH) -build-mode:exe

SHADER_PROCCESOR_PATH := bin/shader_proccesor
COMPILE_SHADER_PROCCESOR := odin build shader -out:$(SHADER_PROCCESOR_PATH) -build-mode:exe

COMMON_FLAGS := -vet-cast -vet-semicolon -vet-shadowing -vet-style -vet-using-param -vet-using-stmt -thread-count:12 -warnings-as-errors -vet-unused-variables
DEBUG_FLAGS := $(COMMON_FLAGS) -debug
RELEASE_FLAGS := $(COMMON_FLAGS) -o:speed -lto:thin -no-bounds-check

.PHONY: shad r_shad debug release t r rr

debug: r_shad
	@echo "debug compile main"
	$(COMPILE_MAIN) $(DEBUG_FLAGS)

release: r_shad
	@echo "release compile"
	$(COMPILE_MAIN) $(RELEASE_FLAGS)

t:
	odin test . -all-packages

r: debug
	./$(MAIN_EXE_PATH)

rr: release
	./$(MAIN_EXE_PATH)

shad:
	@echo "debug compile shader processor"
	$(COMPILE_SHADER_PROCCESOR) $(DEBUG_FLAGS)

r_shad:
	./$(SHADER_PROCCESOR_PATH) pipeline.odin $$(fd -HI -tf -eslang)

