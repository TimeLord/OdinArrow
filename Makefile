SRC   := src
TESTS := tests
BIN   := bin

# Apache Arrow C++ paths — resolved from the bundled PyArrow installation.
ARROW_IDIR := $(shell python3 -c "import pyarrow; print(pyarrow.get_include())" 2>/dev/null)
ARROW_LDIR := $(shell python3 -c "import pyarrow; print(pyarrow.get_library_dirs()[0])" 2>/dev/null)
ARROW_VER  := 2400

ARROW_CPP_FLAGS  := -std=c++20 -O3 -I$(ARROW_IDIR)
ARROW_LINK_FLAGS := -L$(ARROW_LDIR) \
    -l:libarrow.so.$(ARROW_VER) \
    -l:libarrow_compute.so.$(ARROW_VER) \
    -Wl,-rpath,$(ARROW_LDIR)

PARQUET_LINK_FLAGS := -L$(ARROW_LDIR) \
    -l:libarrow.so.$(ARROW_VER) \
    -l:libparquet.so.$(ARROW_VER) \
    -Wl,-rpath,$(ARROW_LDIR)

TEST_DATA := $(HOME)/Work/Projects/Odin/test_data.parquet

.PHONY: all test test-cpp bench-odin bench-python bench bench-compare \
        build-arrow-capi bench-arrow-cpp \
        build-parquet-capi parquet-odin parquet-ffi bench-parquet \
        csv-to-parquet-odin csv-to-parquet-ffi clean

all: test

$(BIN):
	mkdir -p $(BIN)

lib:
	mkdir -p lib

# ── Odin tests (no C++ dependency) ───────────────────────────────────────────

test: $(BIN)
	odin test $(TESTS) -out:$(BIN)/test_runner -vet -strict-style

# ── Arrow C++ shared library (for Odin FFI) ───────────────────────────────────

lib/libarrow_capi.so: benchmarks/cpp/arrow_capi.cpp benchmarks/cpp/arrow_capi.h | lib
	g++ $(ARROW_CPP_FLAGS) -shared -fPIC \
	    benchmarks/cpp/arrow_capi.cpp \
	    $(ARROW_LINK_FLAGS) \
	    -Wl,-rpath,'$$ORIGIN' \
	    -o $@

build-arrow-capi: lib/libarrow_capi.so

# ── Odin tests that link Arrow C++ ───────────────────────────────────────────

test-cpp: lib/libarrow_capi.so $(BIN)
	odin test tests_cpp/ -out:$(BIN)/test_runner_cpp -vet \
	    -extra-linker-flags="-Wl,-rpath,$(realpath lib) -Wl,-rpath,$(ARROW_LDIR)"

# ── Standalone Arrow C++ benchmark binary ─────────────────────────────────────

bin/bench_arrow_cpp: benchmarks/cpp/bench_arrow_main.cpp \
                     benchmarks/cpp/arrow_capi.cpp \
                     benchmarks/cpp/arrow_capi.h | $(BIN)
	g++ $(ARROW_CPP_FLAGS) \
	    benchmarks/cpp/bench_arrow_main.cpp \
	    benchmarks/cpp/arrow_capi.cpp \
	    $(ARROW_LINK_FLAGS) \
	    -o $@

bench-arrow-cpp: bin/bench_arrow_cpp
	bin/bench_arrow_cpp

# ── Python benchmarks ─────────────────────────────────────────────────────────

bench-odin: $(BIN)
	odin run benchmarks/odin -out:$(BIN)/bench_runner -o:speed

bench-python:
	python3 benchmarks/python/bench_array.py
	python3 benchmarks/python/bench_compute.py

bench: bench-odin bench-python

# ── Full 3-way comparison ─────────────────────────────────────────────────────

bench-compare: bin/bench_arrow_cpp $(BIN)
	bash benchmarks/compare.sh

# ── Parquet → CSV: Arrow C++ FFI shared library ───────────────────────────────

lib/libparquet_capi.so: benchmarks/cpp/parquet_capi.cpp benchmarks/cpp/parquet_capi.h | lib
	g++ $(ARROW_CPP_FLAGS) -shared -fPIC \
	    benchmarks/cpp/parquet_capi.cpp \
	    $(PARQUET_LINK_FLAGS) \
	    -Wl,-rpath,'$$ORIGIN' \
	    -o $@

build-parquet-capi: lib/libparquet_capi.so

# ── Parquet → CSV programs ────────────────────────────────────────────────────

bin/parquet_to_csv_odin: programs/parquet_to_csv_odin/*.odin | $(BIN)
	odin build programs/parquet_to_csv_odin -out:$@ -o:speed

bin/parquet_to_csv_ffi: programs/parquet_to_csv_ffi/main.odin lib/libparquet_capi.so | $(BIN)
	odin build programs/parquet_to_csv_ffi -out:$@ -o:speed \
	    -extra-linker-flags="-Wl,-rpath,$(realpath lib) -Wl,-rpath,$(ARROW_LDIR)"

parquet-odin: bin/parquet_to_csv_odin

parquet-ffi: bin/parquet_to_csv_ffi

# ── CSV → Parquet programs ────────────────────────────────────────────────────

bin/csv_to_parquet_odin: programs/csv_to_parquet_odin/*.odin | $(BIN)
	odin build programs/csv_to_parquet_odin -out:$@ -o:speed

bin/csv_to_parquet_ffi: programs/csv_to_parquet_ffi/main.odin lib/libparquet_capi.so | $(BIN)
	odin build programs/csv_to_parquet_ffi -out:$@ -o:speed \
	    -extra-linker-flags="-Wl,-rpath,$(realpath lib) -Wl,-rpath,$(ARROW_LDIR)"

csv-to-parquet-odin: bin/csv_to_parquet_odin

csv-to-parquet-ffi: bin/csv_to_parquet_ffi

# ── Parquet benchmark ─────────────────────────────────────────────────────────

bench-parquet: bin/parquet_to_csv_odin bin/parquet_to_csv_ffi
	bash benchmarks/parquet_bench.sh $(TEST_DATA)

clean:
	rm -rf $(BIN) lib
